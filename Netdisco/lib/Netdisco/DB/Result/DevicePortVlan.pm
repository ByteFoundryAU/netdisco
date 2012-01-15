use utf8;
package Netdisco::DB::Result::DevicePortVlan;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';
__PACKAGE__->table("device_port_vlan");
__PACKAGE__->add_columns(
  "ip",
  { data_type => "inet", is_nullable => 0 },
  "port",
  { data_type => "text", is_nullable => 0 },
  "vlan",
  { data_type => "integer", is_nullable => 0 },
  "native",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "creation",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 1,
    original      => { default_value => \"now()" },
  },
  "last_discover",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 1,
    original      => { default_value => \"now()" },
  },
);
__PACKAGE__->set_primary_key("ip", "port", "vlan");


# Created by DBIx::Class::Schema::Loader v0.07015 @ 2012-01-07 14:20:02
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:/3KLjJ3D18pGaPEaw9EU5w

__PACKAGE__->belongs_to( device => 'Netdisco::DB::Result::Device', 'ip' );
__PACKAGE__->belongs_to( port => 'Netdisco::DB::Result::DevicePort', {
    'foreign.ip' => 'self.ip', 'foreign.port' => 'self.port',
});
__PACKAGE__->belongs_to( vlan => 'Netdisco::DB::Result::DeviceVlan', {
    'foreign.ip' => 'self.ip', 'foreign.vlan' => 'self.vlan',
});

1;