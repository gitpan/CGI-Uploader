package CGI::Uploader;

use 5.005;
use strict;
use CGI::Carp;
require Exporter;
use vars qw($VERSION);

$VERSION = '0.30_01';

=pod

=head1 NAME

CGI::Uploader - Manage CGI uploads using SQL database

=head1 SYNOPSIS

 # Define your upload form field names as hash keys along with
 # any thumbnails they might need, and their max width and heights.

 my %Uploads = (
 	img_1 => {
		thumbs => [
			{ name => 'img_1_thumb_1', w => 100, h => 100 }, 
			{ name => 'img_1_thumb_2', w => 50 , h => 50  }, 
 		],
	},

	# A simple syntax if you just want some thumbnails
 	img_2 => [
 		{ name => 'img_2_thumb_1', w => 100, h => 100 },
 	],

	# And a very simple syntax if you want to store the file untouched. 
 	img_3 => [],
 );
 
 my $u = CGI::Uploader->new(
 	spec       => \%Uploads,

 	updir_url  => 'http://localhost/uploads',
 	updir_path => '/home/user/www/uploads',

 	dbh	       => $dbh,	
	query      => $q, # defaults to CGI->new(),
 );

 # ... now do something with $u

updir_url and updir_path should not include a trailing slash.

=head1 DESCRIPTION

This module is designed to help with the task of managing files uploaded
through a CGI application. The files are stored on the file system, and
the file attributes stored in a SQL database. 

It expects that you have a SQL table dedicated to describing uploads, designed like this:

	-- Note the MySQL specific syntax here
	create table uploads (
		upload_id	int AUTO_INCREMENT primary key not null,
		mime_type   character varying(64),
		extension   character varying(8), -- file extension
		width       integer,                 
		height      integer
	)

For Postgres, a sequence is also required. This can be named
in the constructor, or the default of C<upload_id_seq> will be used. 

Sample SQL scripts are included in the distribution to create such tables.

Other table names are allowed, but at least these fields must be present
in the table.

The expectation is that these file uploads will be related to 
at least one other entity in the database. Tables which reference 
the uploads table can do so with any column name that ends in '_id'.
Column definitions to store photos with an addressbook might look like this:

 CREATE TABLE address_book (
    friend_id          int primary key,
    name               varchar(64),
    photo_id            int,
    photo_thumbnail_id  int
 );

=head1 METHODS

=head2 new()

To create the object, provide a specification the tells what field names are
for files you want to manage, and the details any thumbnails that will be
created for these files (if they are images). Here the file names are given
without the "_id" part:

 my %Uploads = {
 	img_1 => [
        # The first image has 2 different sized thumbnails 
        # that need to be created.
 		{ name => 'img_1_thumb_1', w => 100, h => 100 }, 
 		{ name => 'img_1_thumb_2', w => 50 , h => 50  }, 
 		],
 	img_2 => [
 		{ name => 'img_2_thumb_1', w => 100, h => 100 },
 	],
 	img_3 => [],
 };

The C<new()> constructor accepts the attributes described here:

 my $u = CGI::Uploader->new(
 	spec       => \%Uploads,

 	updir_url  => 'http://localhost/uploads',
 	updir_path => '/home/user/www/uploads',

 	dbh	       => $dbh,	
	query      => $q, # defaults to CGI->new(),

 	up_table   => 'uploads', # defaults to "uploads"
	up_seq     => 'upload_id_seq',  # Required for Postgres
 );

=over 4

=item spec

The spec described above. Required.

=item updir_url

URL to upload storage directory. Required.

=item updir_path

File system path to upload storage directory. Required.

=item dbh

DBI database handle. Required.

=item query

A CGI.pm-compatible object, used for the C<param> and C<upload> functions. 
Defaults to CGI->new() if omitted.

=item up_table

Name of SQL table where uploads are stored. See example sytax above 
or one of the creation scripts included in the distribution. Defaults 
to "uploads" if omitted.

=item up_seq

For Postgres only, the name of a sequence used to generate the upload_ids.
Defaults to C<upload_id_seq> if omitted.

=item

=back 

=cut

use Params::Validate qw/:all/;
use CGI;

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my %in = validate( @_, { 
		updir_url   => { type => SCALAR },
		updir_path  => { type => SCALAR },
		dbh		    => 1,
		up_table    => { default=> 'uploads'},
		up_seq      => { default=> 'upload_id_seq'},
		spec        => { type => HASHREF },
		query	    => { default => CGI->new() },
	});
	$in{db_driver} = $in{dbh}->{Driver}->{Name};
	unless (($in{db_driver} eq 'mysql') or ($in{db_driver} eq 'Pg')) {
		die "only mysql and Pg drivers are supported at this time.
			Update the code in store_meta() to add another driver";
	}

	# Transform two styles of input into standard internal structure
	for my $k (keys %{ $in{spec} }) {
		if (ref $in{spec}->{$k} eq 'ARRAY') {
			$in{spec}->{$k} = {
				thumbs => $in{spec}->{$k},
			}
		}
	}


	my $self  = \%in;
	bless ($self, $class);
	return $self;
}



=pod 


=head2 store_uploads($results)

 my $entity = $u->store_uploads($results);

stores uploaded files based on the definition given in
C<spec>. 

Specifically, it does the following:

=over

=item o

creates any needed thumbnails

=item o

stores all the files on the file system

=item o

inserts upload details into the database, including upload_id, 
mime_type and extension. The columns 'width' and 'height' will be
populated if that meta data is available.

=back

As input, a L<Data::FormValidator::Results|Data::FormValidator::Results> object is expected.
Furthermore, the L<Data::FormValidator::Constraints::Upload|Data::FormValidator::Constraints::Upload> module
is expected to have been used to the generate meta data that
will be used.

The expection is that you are validating some entity which has some files
attached to it.

It returns a hash reference of the valid data with some transformations.
File upload fields will be removed from the hash, and corresponding "_id"
fields will be added.

So for a file upload field named 'img_field',  the 'img_field' key
will be removed from the hash and 'img_field_id' will be added, with
the appropriate upload ID as the value.

=cut 

sub store_uploads {
	validate_pos(@_,1,1);
	my $self = shift;
	my $results = shift;
	my $imgs = $self->{spec};

	my (%add_to_valid);
	my $q = $self->{query};

	for my $i (keys %$imgs) {
		if (my $info = $results->meta($i)) {
			my %ids = $self->create_store_thumbs($i,$info,$imgs->{$i}->{thumbs});
			%add_to_valid = (%add_to_valid, %ids);

            # insert
            my $id = $self->store_meta($info);
			
			$add_to_valid{$i.'_id'} = $id;

            $self->store_file($q,$i,$id,$info->{extension});
			
		}
	}

	# Now add and delete as needed
	my $entity = $results->valid;
	$entity = { %$entity, %add_to_valid };
	map { delete $entity->{$_} } keys %{ $self->{spec} };

	return $entity;
}

=pod 

=head2 delete_checked_uploads()

	my @deleted_field_ids = $u->delete_checked_uploads;

This method deletes all uploads and any associated thumbnails
based on form input. File system files as well as database rows are removed.

It looks through all the field names defined in C<spec>. For an upload named
I<img_1>, a field named I<img_1_delete> is checked to see if it has a true
value. 

A list of the field names is returned, prepended with '_id', such as:

	img_1_id

The expectation is that you have colums with this name defined in another table, 
and by deleting these field names from the $valid hash, they will be set to NULL 
when that database table is updated.

=cut 

# Removes any uploads marked for deletion and their associated thumbnails
sub delete_checked_uploads {
	my $self = shift;
	my $imgs = $self->{spec};
	my %FORM = $self->{query}->Vars;
	my @to_delete;

 	for my $i (keys %$imgs) {
		if ($FORM{$i.'_delete'}) {
			push @to_delete, $self->delete_upload(name => $i);
			
			# For each thumbnail:
			for my $thumb (@{ $imgs->{$i}->{thumbs} }) {
				push @to_delete, $self->delete_upload(name => $thumb->{name});
			}
		}

	}
	return @to_delete;
}

=pod

=head2 delete_upload()

	# Provide the file upload field name
	my $field_name = $u->delete_upload(name => 'img_1');

	# Or the upload_id 
	my $field_name = $u->delete_upload(upload_id => 14 );

This method is used to delete a row in the uploads table and file system file associated
with a single upload.  Usually it's more convenient to use C<delete_checked_uploads>
than to call this method.

There are two ways to call it. The first to provide the name
of the file upload field used: 

	my $field_name = $u->delete_upload(name => 'img_1');

Here, it expects tofind a query field name
with the same prefix and '_id' appended (ie: I<img_1_id>).
The id field should contain the upload_id to delete.

As an alternate interface, you can provide the upload_id directly:

	my $field_name = $u->delete_upload(upload_id => 14 );

The method returns the field name deleted, with "_id" included. 

=cut

sub delete_upload {
	my $self = shift;
	my %in = @_;

	my $id = $in{upload_id};
	my $prefix = $in{name};

	my %FORM = $self->{query}->Vars;

	unless ($id) {
		# before we delete anything with it, verify it's an integer.
		$FORM{$prefix.'_id'} =~ /(^\d+$)/ 
			|| die "no id for upload named $prefix";
		$id = $1;
	}

    $self->delete_file($id);
    $self->delete_meta($id);

	# return field name to delete
	return $prefix.'_id';
}

=pod

=head2 meta_hashref()

	my $tmpl_vars_ref = $u->meta_hashref($table,\%where,@prefixes);

This method is used to return a hash reference suitable for sending to HTML::Template.
Here's an example:

	my $tmpl_vars_ref = $u->meta_hashref('news',{ item_id => 23 },qw/file_1/);

This is going to fetch the file information from the upload table for using the row 
where news.item_id = 23 AND news.file_1_id = uploads.upload_id.
The result might look like this:

	{
		file_1_id     => 523,
		file_1_url    => 'http://localhost/images/uploads/523.pdf',
	}

If the files happen to be images and have their width and height
defined in the database row, template variables will be made
for these as well. 

The C<%where> hash mentioned here is a L<SQL::Abstract|SQL::Abstract> where clause. The
complete SQL that used to fetch the data will be built like this:

 SELECT upload_id as id,width,height,extension 
	FROM uploads, $table where (upload_id = ${prefix}_id and (%where_clause_expanded here));

=cut 
	
sub meta_hashref {
	validate_pos(@_,1,
		{ type => SCALAR },
		{ type => HASHREF },
		(0) x (@_ - 3) );
	my $self = shift;
	my $table = shift; 
	my $where = shift;
	my @prefixes = @_;
	my $DBH = $self->{dbh};
	my %fields;
	require SQL::Abstract;
	my $sql = SQL::Abstract->new;
	my ($stmt,@bind) = $sql->where($where);
	
	# We don't want the 'WHERE' word that SQL::Abstract adds
	$stmt =~ s/^\s?WHERE//;


	# make a random number available to defeat image caching.
	my $rand = (int rand 100);

	# XXX There is probably a more efficient way to get this data than using N selects

	my $qt = ($DBH->{Driver}->{Name} eq 'mysql') ? '`' : '"'; # mysql uses non-standard quoting

	for my $prefix (@prefixes) {
		my $img = $DBH->selectrow_hashref(qq!
			SELECT upload_id as id,width,height,extension 
				FROM !.$self->{up_table}.qq!, $table as t
				WHERE (upload_id = t.${qt}${prefix}_id${qt} and ($stmt) )!,
				{},@bind);

		if ($img->{id}) {
			$fields{$prefix.'_url'} =
				$self->{updir_url}."/$img->{id}$img->{extension}?$rand";
			for my $k (qw/width height id/) {
				$fields{$prefix.'_'.$k} = $img->{$k} if defined $img->{$k};
			}
		}
	}

	return \%fields;
}

# create and store thumb nails based on input hash
# return hash with thumbnail field names and ids
sub create_store_thumbs {
	validate_pos(@_,1,1,
		{ type => HASHREF },
		{ type => ARRAYREF },
	);
	my $self = shift;
	my $f = shift;
	my $info = shift;
	my $thumbs = shift;
	my $q = $self->{query};
	my %out;

	require Image::Magick;
	my $img = Image::Magick->new();

	$img->Read(filename=>$q->tmpFileName($q->param($f)));

	my ($w,$h) = ($info->{width},$info->{height});
	for my $attr (@$thumbs) {
		# resize as needed
		if ($w > $attr->{w} or $h > $attr->{h}) {
			$img->Resize($attr->{w}.'x'.$attr->{h}); 
		}

		# inherit mime-type and extension from parent
		my %t_info =  %$info;
		($t_info{width}, 
			$t_info{height}) = $img->Get('width','height');

		# Insert		
		my $id = $self->store_meta(\%t_info);

		# Add to output hash
		$out{$attr->{name}.'_id'} = $id;

        my $err = $self->store_thumb($img,$id,$t_info{extension});
        if ($err) {
            warn $err;
            my $code;
            # codes > 400 are fatal 
            if ((($code) = $err =~ /(\d+)/) and ($code > 400)) {
                die "$err";
            }
        }
	}
	return %out;
}

sub delete_meta {
    my $self = shift;
    my $id = shift;
	my $DBH = $self->{dbh};

    $DBH->do("DELETE from ".$self->{up_table}." WHERE upload_id = $id");

}

sub delete_file {
    my $self = shift;
    my $id   = shift;

    my ($file) = glob($self->{updir_path}."/${id}.*");
    if (-e $file) {  
        unlink $file || die "couldn't delete upload  file: $file:  $!";
    }

}


sub store_thumb {
    my $self = shift;
    my ($img,$id,$ext) = @_;
    my $err = $img->Write($self->{updir_path}.'/'.$id.$ext);
    return $err;
}


sub store_file {
    my $self = shift;
    my ($q,$field,$id,$ext) = @_;
    
    require File::Copy;	
    import File::Copy;

    copy($q->tmpFileName($q->param($field)),
        $self->{updir_path}."/$id".$ext)
    || die 'Unexpected error occured when uploading the image.';

}


# looks for field_info field, 
# inserts into uploads table
# returns inserted ids

sub store_meta {
	my $self = shift;
	my (@fields) = @_;

	my $DBH = $self->{dbh};

	require SQL::Abstract;
	my $sql = SQL::Abstract->new;
	my @ids;
	for my $href (@fields) {
		if (ref $href eq 'HASH') {
			# remove unknown fields
			my %known;	
			@known{qw/mime_type width height extension upload_id/} = (1,1,1,1,1);
			map { delete $href->{$_} unless $known{$_} } keys %$href;

			my $id;
			if ($self->{db_driver} eq 'Pg') {
				$id = $DBH->selectrow_array("SELECT NEXTVAL('".$self->{up_seq}."')");
				$href->{upload_id} = $id;
			}
			my ($stmt,@bind) = $sql->insert($self->{up_table},$href);
			$DBH->do($stmt,{},@bind);
			if ($self->{db_driver} eq 'mysql') {
				$id = $DBH->{'mysql_insertid'};
			}
			push @ids, $id;
		}
		else {
			push @ids, undef;
		}
	}
	return wantarray ? @ids : $ids[0];
}

=pod

=head2 names()

Returns an array of all the upload names, including any thumbnails.

=cut

sub names {
	my $self = shift;
	my $imgs = $self->{spec};

	return keys %$imgs,  # primary images
		map { map { $_->{name}   } @{ $$imgs{$_}->{thumbs} } } keys %$imgs;  # thumbs
}



1;
__END__


=head1 AUTHOR

Mark Stosberg <mark@summersault.com>

=head1 LICENSE 

This program is free software; you can redistribute it and/or modify
it under the terms as perl itself.
