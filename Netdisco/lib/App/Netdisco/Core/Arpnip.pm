package App::Netdisco::Core::Arpnip;

use Dancer qw/:syntax :script/;
use Dancer::Plugin::DBIC 'schema';

use App::Netdisco::Util::PortMAC ':all';
use App::Netdisco::Util::DNS ':all';
use NetAddr::IP::Lite ':lower';
use Time::HiRes 'gettimeofday';
use Net::MAC;

use base 'Exporter';
our @EXPORT = ();
our @EXPORT_OK = qw/ do_arpnip check_mac store_arp /;
our %EXPORT_TAGS = (all => \@EXPORT_OK);

=head1 NAME

App::Netdisco::Core::Arpnip

=head1 DESCRIPTION

Helper subroutines to support parts of the Netdisco application.

There are no default exports, however the C<:all> tag will export all
subroutines.

=head1 EXPORT_OK

=head2 do_arpnip( $device, $snmp )

Given a Device database object, and a working SNMP connection, connect to a
device and discover its ARP cache for IPv4 and Neighbor cache for IPv6.

Will also discover subnets in use on the device and update the Subnets table.

=cut

sub do_arpnip {
  my ($device, $snmp) = @_;

  unless ($device->in_storage) {
      debug sprintf ' [%s] arpnip - skipping device not yet discovered', $device->ip;
      return;
  }

  my $port_macs = get_port_macs($device);

  # get v4 arp table
  my @v4 = _get_arps($device, $port_macs, $snmp->at_paddr, $snmp->at_netaddr);
  # get v6 neighbor cache
  my @v6 = _get_arps($device, $port_macs, $snmp->ipv6_n2p_mac, $snmp->ipv6_n2p_addr);

  # get directly connected networks
  my @subnets = _gather_subnets($device, $snmp);
  # TODO: IPv6 subnets

  # would be possible just to use now() on updated records, but by using this
  # same value for them all, we _can_ if we want add a job at the end to
  # select and do something with the updated set (no reason to yet, though)
  my $now = 'to_timestamp('. (join '.', gettimeofday) .')';

  # update node_ip with ARP and Neighbor Cache entries
  store_arp(@$_, $now) for @v4;
  debug sprintf ' [%s] arpnip - processed %s ARP Cache entries',
    $device->ip, scalar @v4;

  store_arp(@$_, $now) for @v6;
  debug sprintf ' [%s] arpnip - processed %s IPv6 Neighbor Cache entries',
    $device->ip, scalar @v6;

  _store_subnet($_, $now) for @subnets;
  debug sprintf ' [%s] arpnip - processed %s Subnet entries',
    $device->ip, scalar @subnets;
}

# get an arp table (v4 or v6)
sub _get_arps {
  my ($device, $port_macs, $paddr, $netaddr) = @_;
  my @arps = ();

  while (my ($arp, $node) = each %$paddr) {
      my $ip = $netaddr->{$arp};
      next unless defined $ip;
      push @arps, [$node, $ip, hostname_from_ip($ip)]
        if check_mac($device, $node, $port_macs);
  }

  return @arps;
}

=head2 check_mac( $device, $node, $port_macs? )

Given a Device database object and a MAC address, perform various sanity
checks which need to be done before writing an ARP/Neighbor entry to the
database storage.

Returns false, and logs a debug level message, if the checks fail.

Returns a true value if these checks pass:

=over 4

=item *

MAC address is not malformed

=item *

MAC address is not broadcast, CLIP, VRRP or HSRP

=item *

MAC address does not belong to an interface on C<$device>

=back

Optionally pass a cached set of Device port MAC addresses as the fourth
argument, or else C<check_mac> will retrieve this for itself from the
database.

=cut

sub check_mac {
  my ($device, $node, $port_macs) = @_;
  $port_macs ||= get_port_macs($device);
  my $mac = Net::MAC->new(mac => $node, 'die' => 0, verbose => 0);

  # incomplete MAC addresses (BayRS frame relay DLCI, etc)
  if ($mac->get_error) {
      debug sprintf ' [%s] arpnip - mac [%s] malformed - skipping',
        $device->ip, $node;
      return 0;
  }
  else {
      # lower case, hex, colon delimited, 8-bit groups
      $node = lc $mac->as_IEEE;
  }

  # broadcast MAC addresses
  return 0 if $node eq 'ff:ff:ff:ff:ff:ff';

  # CLIP
  return 0 if $node eq '00:00:00:00:00:01';

  # VRRP
  if (index($node, '00:00:5e:00:01:') == 0) {
      debug sprintf ' [%s] arpnip - VRRP mac [%s] - skipping',
        $device->ip, $node;
      return 0;
  }

  # HSRP
  if (index($node, '00:00:0c:07:ac:') == 0) {
      debug sprintf ' [%s] arpnip - HSRP mac [%s] - skipping',
        $device->ip, $node;
      return 0;
  }

  # device's own MACs
  if (exists $port_macs->{$node}) {
      debug sprintf ' [%s] arpnip - mac [%s] is device port - skipping',
        $device->ip, $node;
      return 0;
  }

  return 1;
}

=head2 store_arp( $mac, $ip, $name, $now? )

Stores a new entry to the C<node_ip> table with the given MAC, IP (v4 or v6)
and DNS host name.

Will mark old entries for this IP as no longer C<active>.

Optionally a literal string can be passed in the fourth argument for the
C<time_last> timestamp, otherwise the current timestamp (C<now()>) is used.

=cut

sub store_arp {
  my ($mac, $ip, $name, $now) = @_;
  $now ||= 'now()';

  schema('netdisco')->txn_do(sub {
    my $current = schema('netdisco')->resultset('NodeIp')
      ->search({ip => $ip, -bool => 'active'})
      ->search(undef, {
        columns => [qw/mac ip/],
        order_by => [qw/mac ip/],
        for => 'update'
      });
    $current->first; # lock rows
    $current->update({active => \'false'});

    schema('netdisco')->resultset('NodeIp')
      ->search({'me.mac' => $mac, 'me.ip' => $ip})
      ->update_or_create(
      {
        dns => $name,
        active => \'true',
        time_last => \$now,
      },
      {
        order_by => [qw/mac ip/],
        for => 'update',
      });
  });
}

# gathers device subnets
sub _gather_subnets {
  my ($device, $snmp) = @_;
  my @subnets = ();

  my $ip_netmask = $snmp->ip_netmask;
  my $localnet = NetAddr::IP::Lite->new('127.0.0.0/8');

  foreach my $entry (keys %$ip_netmask) {
      my $ip = NetAddr::IP::Lite->new($entry);
      my $addr = $ip->addr;

      next if $addr eq '0.0.0.0';
      next if $ip->within($localnet);
      next if setting('ignore_private_nets') and $ip->is_rfc1918;

      my $netmask = $ip_netmask->{$addr};
      next if $netmask eq '255.255.255.255' or $netmask eq '0.0.0.0';

      my $cidr = NetAddr::IP::Lite->new($addr, $netmask)->network->cidr;

      debug sprintf ' [%s] arpnip - found subnet %s', $device->ip, $cidr;
      push @subnets, $cidr;
  }

  return @subnets;
}

# update subnets with new networks
sub _store_subnet {
  my ($subnet, $now) = @_;

  schema('netdisco')->txn_do(sub {
    schema('netdisco')->resultset('Subnet')->update_or_create(
    {
      net => $subnet,
      last_discover => \$now,
    },
    { for => 'update' });
  });
}

1;
