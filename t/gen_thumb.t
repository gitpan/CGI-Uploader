# Please don't remove the next line. Thanks. -mark
#arch-tag: Mark_Stosberg_<mark@summersault.com>--2004-04-19_20:22:34

use Test::More qw/no_plan/;
use Test::Differences;
use Carp::Assert;
use lib 'lib';
use strict;

BEGIN { 
    use_ok('CGI::Uploader');
    use_ok('File::Path');
    use_ok('Image::Size');
    use_ok('DBI');
    use_ok('CGI');
};

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

	 my %imgs = (
		'img_1' => [
            { name => 'img_1_thumb', w => 10 }
        ],
	 );

	 my $u = 	CGI::Uploader->new(
		updir_path=>'t/uploads',
		updir_url=>'http://localhost/test',
		dbh  => $DBH,
		spec => \%imgs,
        query => CGI->new(),
	 );
	 ok($u, 'Uploader object creation');

     my ($thumb_tmp_filename)  = $u->gen_thumb(
         filename => 't/20x16.png',
         w => 10,
     );

     my ($w,$h) = imgsize($thumb_tmp_filename); 
     is($h,8,'correct height only width is supplied');

     ($thumb_tmp_filename)  = $u->gen_thumb(
         filename => 't/20x16.png',
         h => 8,
     );

     ($w,$h) = imgsize($thumb_tmp_filename); 
     is($w,10,'correct width only width is supplied');

###
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

     eval {
         my %entity_upload_extra = $u->store_upload(
             file_field  => 'img_1',
             src_file    => 't/20x16.png',
             uploaded_mt => 'image/png',
             file_name   => '20x16.png',
             );
         };
    is($@,'', 'store_upload() survives');

    my $db_height =$DBH->selectrow_array(
        "SELECT height
            FROM uploads 
            WHERE upload_id = 2");
    is($db_height, 8, "correct height calculation when thumb height omitted from spec ");

}

	
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
    $DBH->disconnect;
};
 

