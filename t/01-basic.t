# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl 1.t'

#########################

use Test::More qw/no_plan/;
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
          'HTTP_USER_AGENT' => 'Mozilla/5.0 (compatible; Konqueror/2.1.1; X11)',
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

	my $default = {
		required=>[qw/100x100_gif 300x300_gif/],
		validator_packages=> 'Data::FormValidator::Constraints::Upload',
		constraints => {
			'100x100_gif' => [
				{
					constraint_method => 'file_format',
					params=>[],
				},
				{
					constraint_method => 'image_max_dimensions',
					params=>[\300,\300],
				}
			],
			'300x300_gif' => [
				{
					constraint_method => 'file_format',
					params=>[],
				},
				{
					constraint_method => 'image_max_dimensions',
					params=>[\300,\300],
				}
			],
		},
	};


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
	 );
	 ok($u, 'Uploader object creation');

	 my $results = Data::FormValidator->check($q,$default);

	 ok($results, 'creating DFV valid object');

 	 my ($entity);
	 eval {
 	 	($entity) = $u->store_uploads($results);

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
	row_ok( sql   => "SELECT * FROM uploads  ORDER BY upload_id LIMIT 1",
                tests => {
					'eq' => {
						mime_type => 'image/gif',
						extension => '.gif',
					},
					'=~' => {
						upload_id => qr/^\d+/,
						width 	=> qr/^\d+/,
						height 	=> qr/^\d+/,
					},
				} ,
                label => "reality checking a database row");

	my $row_cnt = $DBH->selectrow_array("SELECT count(*) FROM uploads ");
	ok($row_cnt == 6, 'number of rows in database');

	 $q->param('100x100_gif_id',1);
	 $q->param('img_1_thumb_1_id',2);
	 $q->param('img_1_thumb_2_id',3);
	 $q->param('100x100_gif_delete',1);
	 my @deleted_field_ids = $u->delete_checked_uploads;

	 ok(eq_set(\@deleted_field_ids,['100x100_gif_id','img_1_thumb_1_id','img_1_thumb_2_id']), 'delete_checked_uploads returned field ids');

	 @files = <t/uploads/*>;	
	ok(scalar @files == 3, 'expected number of files removed');

	$row_cnt = $DBH->selectrow_array("SELECT count(*) FROM uploads ");
	ok($row_cnt == 3, 'number of rows removed');

	my $qt = ($drv eq 'mysql') ? '`' : '"'; # mysql has a funny way of quoting
	ok($DBH->do(qq!INSERT INTO cgi_uploader_test (item_id,${qt}100x100_gif_id$qt,img_1_thumb_1_id) VALUES (1,6,5)!), 'test data insert');
	my $tmpl_vars_ref = $u->meta_hashref('cgi_uploader_test',{item_id => 1},qw/100x100_gif img_1_thumb_1/);

	ok (eq_set(
			[qw/
				img_1_thumb_1_height img_1_thumb_1_width img_1_thumb_1_url img_1_thumb_1_id
				100x100_gif_height 100x100_gif_width 100x100_gif_url 100x100_gif_id
			/],
			[keys %$tmpl_vars_ref],
		), 'create_img_tmpl_var keys returned');

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
 

