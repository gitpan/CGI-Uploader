#########################
# Please don't remove the next line. Thanks.
# arch-tag: Mark_Stosberg_<mark@summersault.com>--2004-03-27_21:15:22

use Test::More qw/no_plan/;
use Test::Differences;
use lib 'lib';
use strict;

BEGIN { use_ok('CGI::Uploader') };
BEGIN { use_ok('DBI') };
BEGIN { use_ok('CGI') };
BEGIN { use_ok('Data::FormValidator') };
BEGIN { use_ok('Test::DatabaseRow') };

%ENV = (
	%ENV,
          'SCRIPT_NAME' => '/test.cgi',
          'SERVER_NAME' => 'perl.org',
          'HTTP_CONNECTION' => 'TE, close',
          'REQUEST_METHOD' => 'POST',
          'SCRIPT_URI' => 'http://www.perl.org/test.cgi',
          'CONTENT_LENGTH' => '2986',
          'SCRIPT_FILENAME' => '/home/usr/test.cgi',
          'SERVER_SOFTWARE' => 'Apache/1.3.27 (Unix) ',
          'HTTP_TE' => 'deflate,gzip;q=0.3',
          'QUERY_STRING' => '',
          'REMOTE_PORT' => '1855',
          'SERVER_PORT' => '80',
          'REMOTE_ADDR' => '127.0.0.1',
          'CONTENT_TYPE' => 'multipart/form-data; boundary=xYzZY',
          'SERVER_PROTOCOL' => 'HTTP/1.1',
          'PATH' => '/usr/local/bin:/usr/bin:/bin',
          'REQUEST_URI' => '/test.cgi',
          'GATEWAY_INTERFACE' => 'CGI/1.1',
          'SCRIPT_URL' => '/test.cgi',
          'SERVER_ADDR' => '127.0.0.1',
          'DOCUMENT_ROOT' => '/home/develop',
          'HTTP_HOST' => 'www.perl.org'
);

use CGI;
open(IN,'<t/upload_post_text.txt') || die 'missing test file';
binmode(IN);

*STDIN = *IN;
my $q = new CGI;


eval {
	my $med_srv = CGI::Uploader->new();
};
ok($@,'basic functioning of Params::Validate');

use vars qw($dsn $user $password);
my $file ='t/cgi-uploader.config';
my $return;
unless ($return = do $file) {
	warn "couldn't parse $file: $@" if $@;
	warn "couldn't do $file: $!"    unless defined $return;
	warn "couldn't run $file"       unless $return;
}
ok($return, 'loading configuration');


my $DBH =  DBI->connect($dsn,$user,$password);
ok($DBH,'connecting to database'), 

# create uploads table
my $drv = $DBH->{Driver}->{Name};

ok(open(IN, "<create_uploader_table.".$drv.".sql"), 'opening SQL create file');
my $sql = join "\n", (<IN>);
my $created_up_table = $DBH->do($sql);
ok($created_up_table, 'creating uploads table');

ok(open(IN, "<t/create_test_table.sql"), 'opening SQL create test table file');
$sql = join "\n", (<IN>);

# Fix mysql non-standard quoting
$sql =~ s/"/`/gs if ($drv eq 'mysql');

my $created_test_table = $DBH->do($sql);
ok($created_test_table, 'creating test table');

SKIP: {
	 skip "Couldn't create database table", 20 unless $created_up_table;

     # We alter the table to test our mapping
     $DBH->do("ALTER TABLE uploads RENAME upload_id TO upload_id_b");
     $DBH->do("ALTER TABLE uploads RENAME mime_type TO mime_type_b");
     $DBH->do("ALTER TABLE uploads RENAME extension TO extension_b");
     $DBH->do("ALTER TABLE uploads RENAME width TO width_b");
     $DBH->do("ALTER TABLE uploads RENAME height TO height_b");
     $DBH->do("ALTER TABLE uploads ADD COLUMN custom char(64)");

	 my %imgs = (
		'100x100_gif' => [
			{ name => 'img_1_thumb_1', w => 50, h => 50 },
			{ name => 'img_1_thumb_2', w => 50, h => 50 },
		],
		'300x300_gif' => [
			{ name => 'img_2_thumb_1', w => 50, h => 50 },
			{ name => 'img_2_thumb_2', w => 50, h => 50 },
		],
	 );

	 my $u = 	CGI::Uploader->new(
		updir_path=>'t/uploads',
		updir_url=>'http://localhost/test',
		dbh => $DBH,
		query => $q,
		spec => \%imgs,
        up_table_map => {
            upload_id => 'upload_id_b',
            mime_type => 'mime_type_b',
            extension => 'extension_b',
            width     => 'width_b',
            height    => 'height_b',
            custom    => undef,
        }
	 );
	 ok($u, 'Uploader object creation');

     my $form_data = $q->Vars;

 	 my ($entity);
	 eval {
 	 	($entity) = $u->store_uploads($form_data);

 	 };
	 is($@,'', 'calling store_uploads');

	 my @pres = $u->names;
	 ok(eq_set([grep {m/_id$/} keys %$entity ],[map { $_.'_id'} @pres]),
	 	'store_uploads entity additions work');

	ok(not(grep {m/^(300x300_gif|100x100_gif)$/} keys %$entity),
           'store_uploads entity removals work');

	my @files = <t/uploads/*>;	
	ok(scalar @files == 6, 'expected number of files created');

	$Test::DatabaseRow::dbh = $DBH;
	row_ok( sql   => "SELECT * FROM uploads  ORDER BY upload_id_b LIMIT 1",
                tests => {
					'eq' => {
						mime_type_b => 'image/gif',
						extension_b => '.gif',
					},
					'=~' => {
						upload_id_b => qr/^\d+/,
						width_b 	=> qr/^\d+/,
						height_b 	=> qr/^\d+/,
					},
				} ,
                label => "reality checking a database row");

	my $row_cnt = $DBH->selectrow_array("SELECT count(*) FROM uploads ");
	is($row_cnt,6, 'number of rows in database');

	 $q->param('100x100_gif_id',1);
	 $q->param('img_1_thumb_1_id',2);
	 $q->param('img_1_thumb_2_id',3);
	 $q->param('100x100_gif_delete',1);
	 my @deleted_field_ids = $u->delete_checked_uploads;

	 ok(eq_set(\@deleted_field_ids,['100x100_gif_id','img_1_thumb_1_id','img_1_thumb_2_id']), 'delete_checked_uploads returned field ids');


	 @files = <t/uploads/*>;	

	is((scalar @files),3, 'expected number of files removed');

	$row_cnt = $DBH->selectrow_array("SELECT count(*) FROM uploads ");
	is($row_cnt,3, 'number of rows removed');

	my $qt = ($drv eq 'mysql') ? '`' : '"'; # mysql has a funny way of quoting
	ok($DBH->do(qq!INSERT INTO cgi_uploader_test (item_id,${qt}100x100_gif_id$qt,img_1_thumb_1_id) VALUES (1,6,5)!), 'test data insert');
	my $tmpl_vars_ref = $u->meta_hashref('cgi_uploader_test',{item_id => 1},qw/100x100_gif img_1_thumb_1/);

    use Data::Dumper;
	ok (eq_set(
			[qw/
				img_1_thumb_1_height 
                img_1_thumb_1_width 
                img_1_thumb_1_url 
                img_1_thumb_1_id
                img_1_thumb_1_extension
                img_1_thumb_1_mime_type

				100x100_gif_height 
                100x100_gif_width 
                100x100_gif_url 
                100x100_gif_id
                100x100_gif_extension
                100x100_gif_mime_type
			/],
			[keys %$tmpl_vars_ref],
		), 'meta_hashref keys returned') || diag Dumper($tmpl_vars_ref);

};

# We use an end block to clean up even if the script dies.
 END {
 	unlink <t/uploads/*>;
 	if ($DBH) {
 		if ($created_up_table) {
 			$DBH->do("DROP SEQUENCE upload_id_seq") if ($drv eq 'Pg');
 			$DBH->do("DROP TABLE uploads");
 		}
 		if ($created_test_table) {
 			$DBH->do('DROP TABLE cgi_uploader_test');
 		}
 		$DBH->disconnect;
 	}
 };
 

