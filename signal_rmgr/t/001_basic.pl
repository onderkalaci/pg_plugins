# Copyright (c) 2023, PostgreSQL Global Development Group

use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');

$node->init;
$node->append_conf(
	'postgresql.conf', q{
wal_level = 'replica'
max_wal_senders = 4
shared_preload_libraries = 'signal_rmgr'
});
$node->start;

# setup
$node->safe_psql('postgres', 'CREATE EXTENSION signal_rmgr');
$node->safe_psql('postgres', 'CREATE EXTENSION pg_walinspect');

# make sure checkpoints don't interfere with the test.
my $start_lsn = $node->safe_psql('postgres',
	qq[SELECT lsn FROM pg_create_physical_replication_slot('regress_test_slot1', true, false);]);

# Write and save the WAL record's returned end LSN for verifying it later.
# This creates a record for a SIGHUP.
my $record_end_lsn = $node->safe_psql('postgres',
	"SELECT signal_rmgr(1, 'test signal booboo')");

# ensure the WAL is written and flushed to disk
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');

my $end_lsn = $node->safe_psql('postgres', 'SELECT pg_current_wal_flush_lsn()');

# check if our custom WAL resource manager has successfully registered with the server
my $row_count =
  $node->safe_psql('postgres',
	qq[SELECT count(*) FROM pg_get_wal_resource_managers()
		WHERE rm_name = 'signal_rmgr';]);
is($row_count, '1',
	'signal_rmgr has successfully registered with the server'
);

# check if signal_rmgr has successfully written a WAL record.
my $expected = qq($record_end_lsn|signal_rmgr|XLOG_SIGNAL_RMGR|0|signal 1; reason test signal booboo (19 bytes));
my $result =
  $node->safe_psql('postgres',
	qq[SELECT end_lsn, resource_manager, record_type, fpi_length, description FROM pg_get_wal_records_info('$start_lsn', '$end_lsn')
		WHERE resource_manager = 'signal_rmgr';]);
is($result, $expected,
	'WAL record has successfully written'
);

$node->stop;
done_testing();
