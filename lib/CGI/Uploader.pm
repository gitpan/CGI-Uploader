package CGI::Uploader;

use 5.005;
use strict;
use CGI::Carp;
use Params::Validate qw/:all/;
use File::Path;
use File::Spec;
use File::Temp qw/tempfile/;
use Carp::Assert;
use Image::Size;
require Exporter;
use vars qw($VERSION);

$VERSION = '0.70_02';

=head1 NAME

CGI::Uploader - Manage CGI uploads using SQL database

=head1 SYNOPSIS

 my $u = CGI::Uploader->new(
 	spec       => {
        # Upload one image named from the form field 'img' 
        # and create one thumbnail for it. 
        img => [
            { name => 'img_thumb_1', w => 100, h => 100 },
        ],
    }

 	updir_url  => 'http://localhost/uploads',
 	updir_path => '/home/user/www/uploads',

 	dbh	       => $dbh,	
	query      => $q, # defaults to CGI->new(),
 );

 # ... now do something with $u

=head1 DESCRIPTION

This module is designed to help with the task of managing files uploaded
through a CGI application. The files are stored on the file system, and
the file attributes stored in a SQL database. 

=head1 QUICK START

There is a now the L<CGI::Uploader::Cookbook|CGI::Uploader::Cookbook>, which
provides examples how to use this module as part of a basic BREAD web application. 
(Browse, Read, Edit, Add, Delete).  

=head1 METHODS

=head2 new()

 my $u = CGI::Uploader->new(
 	spec       => {
        img_1 => [
            # The first image has 2 different sized thumbnails 
            # that need to be created.
            { name => 'img_1_thumb_1', w => 100, h => 100 }, 
            { name => 'img_1_thumb_2', w => 50 , h => 50  }, 
            ],

        # No thumbnails
        img_2 => [],

        # Downsize the large image to these maximum dimensions if it's larger
        img_3 => {
            downsize => { w => 430 },
            thumbs => [
                { name => 'img_3_thumb_1',  w => 200 },
            ],

        }
    },

 	updir_url  => 'http://localhost/uploads',
 	updir_path => '/home/user/www/uploads',

 	dbh	       => $dbh,	
	query      => $q, # defaults to CGI->new(),

 	up_table   => 'uploads', # defaults to "uploads"
	up_seq     => 'upload_id_seq',  # Required for Postgres
 );

=over 4

=item spec [required]

The spec described above. The keys correspond to form field names for upload 
fields. The values are array references. The simplest case is for the array to 
be empty, which means no thumbnails will be created. For non-image types,  
thumbnails don't make sense anyway. Each element in the array is a hash 
reference with the following keys: 'name', 'w', 'h'. These correspond to the 
name, max width, and max height of the thumbnail.

Also notice there is an option to 'downsize' the large image if needed. Also,
for the C<downsize> and thumbnail size specifications, only one dimension needs
to provided, if that's all you care about. 

=item updir_url [required]

URL to upload storage directory. Should not include a trailing slash.

=item updir_path [required]

File system path to upload storage directory. Should not include a trailing 
slash.

=item dbh [required]

DBI database handle. Required.

=item query

A CGI.pm-compatible object, used for the C<param> and C<upload> functions. 
Defaults to CGI->new() if omitted.

=item up_table

Name of the SQL table where uploads are stored. See example syntax above or one
of the creation scripts included in the distribution. Defaults to "uploads" if 
omitted.

=item up_table_map

A hash reference which defines a mapping between the column names used in your 
SQL table, and those that CGI::Uploader uses. The keys are the CGI::Uploader 
default names. Values are the names that are actually used in your table.

This is not required. It simply allows you to use custom column names.

  upload_id       => 'upload_id',
  mime_type       => 'mime_type',
  extension       => 'extension',
  width           => 'width',
  height          => 'height',   
  thumbnail_of_id => 'thumbnail_of_id',

You may also define additional column names with a value of 'undef'. This feature
is only useful if you override the C<extract_meta()> method or pass in
C<$shared_meta> to store_uploads(). Values for these additional columns will
then be stored by C<store_meta()> and retrieved with C<fk_meta()>.

=item up_seq

For Postgres only, the name of a sequence used to generate the upload_ids.
Defaults to C<upload_id_seq> if omitted.

=item file_scheme

 file_scheme => 'md5',

C<file_scheme> controls how file files are stored on the file system. The default
is C<simple>, which stores all the files in the same directory with names like 
C<123.jpg>. Depending on your environment, this may be sufficient to store
10,000 or more files.

As an alternative, you can specify C<md5>, which will create three levels
of directories based on the first three letters of the ID's md5 sum. The
result may look like this:

 2/0/2/123.jpg

This should scale well to millions of files. If you want even more control,
consider overriding the C<build_loc()> method.

=back 

=cut

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my %in = validate( @_, { 
		updir_url    => { type => SCALAR },
		updir_path   => { type => SCALAR },
		dbh		     => 1,
		up_table     => { 
                          type => SCALAR,
                          default=> 'uploads',
        },
        up_table_map => { 
                          type    => HASHREF,
                          default => {
                              upload_id       => 'upload_id',
                              mime_type       => 'mime_type',
                              extension       => 'extension',
                              width           => 'width',
                              height          => 'height',   
							  thumbnail_of_id => 'thumbnail_of_id',
#                              bytes      => 'bytes',
                          }
        },
		up_seq      => { default => 'upload_id_seq'},
		spec        => { type => HASHREF },
		query	    => { default => CGI->new() } ,
        file_scheme => {
             regex   => qr/^simple|md5$/,
             default => 'simple',
        },

	});
	$in{db_driver} = $in{dbh}->{Driver}->{Name};
	unless (($in{db_driver} eq 'mysql') or ($in{db_driver} eq 'Pg')) {
		die "only mysql and Pg drivers are supported at this time. ";
	}

    unless ($in{query}) {
        require CGI;
        $in{query} = CGI->new; 
    }

	# Transform two styles of input into standard internal structure
	for my $k (keys %{ $in{spec} }) {
		if (ref $in{spec}->{$k} eq 'ARRAY') {
			$in{spec}->{$k} = {
				thumbs => $in{spec}->{$k},
			}
		}
	}

    # Fill in missing map values
    for (keys %{ $in{up_table_map} }) {
        $in{up_table_map}{$_} = $_ unless defined $in{up_table_map}{$_};
    }

    # keep pointer to input hash for easier re-use later
    $in{input} =\%in;

	my $self  = \%in;
	bless ($self, $class);
	return $self;
}

=head2 store_uploads()

  my $entity = $u->store_uploads($form_data);

Stores uploaded files based on the definition given in C<spec>. 

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

As input, a hash reference of form data is expected. The simplest way 
to get this is like this:

 use CGI;
 my $q = new CGI; 
 $form_data = $q->Vars;

However, I recommend that you validate your data with a module with
L<Data::FormValidator|Data::FormValidator>, and use a hash reference
of validated data, instead of directly using the CGI form data.

CGI::Uploader is designed to handle uploads that are included as a part 
of an add/edit form for an entity stored in a database. So, C<$form_data> 
is expected to contain additional fields for this entity as well
as the file upload fields.

For this reason, the C<store_uploads> method returns a hash reference of the
valid data with some transformations.  File upload fields will be removed from
the hash, and corresponding "_id" fields will be added.

So for a file upload field named 'img_field',  the 'img_field' key
will be removed from the hash and 'img_field_id' will be added, with
the appropriate upload ID as the value.

store_uploads takes an optional second argument as well:

  my $entity = $u->store_uploads($form_data,$shared_meta);

This is a hash refeference of additional meta data that you want to store
for all of the images you storing. For example, you may wish to store
an "uploaded_user_id".

The keys should be column names that exist in your C<uploads> table. The values
should be appropriate data for the column.  Only the key names defined by the
C<up_table_map> in C<new()> will be used.  Other values in the hash will be
ignored.

=cut 

sub store_uploads {
	validate_pos(@_,1,1,0);
	my $self        = shift;
	my $form_data   = shift;
    my $shared_meta = shift;
	assert($form_data, 'store_uploads: input hashref missing');

	my $uploads = $self->{spec};

	my %entity_all_extra;
	for my $file_field (keys %$uploads) {
        # If we have an uploaded file for this
        my ($tmp_filename,$uploaded_mt,$file_name) = $self->upload($file_field);
        if ($tmp_filename) {
            my $id_to_update = $form_data->{$file_field.'_id'}; 

            my %entity_upload_extra = $self->store_upload(
                file_field    => $file_field,
                src_file      => $tmp_filename,
                uploaded_mt   => $uploaded_mt,
                file_name     => $file_name,
                shared_meta   => $shared_meta,  
                id_to_update  => $id_to_update, 
            );

            %entity_all_extra = (%entity_all_extra, %entity_upload_extra);
		}
	}

	# Now add and delete as needed
	my $entity = { %$form_data, %entity_all_extra };
	map { delete $entity->{$_} } keys %{ $self->{spec} };

	return $entity;
}

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

sub delete_checked_uploads {
	my $self = shift;
	my $imgs = $self->{spec};

    my $q = $self->{query};

	my @to_delete;

 	for my $i (keys %$imgs) {
		if ($q->param($i.'_delete') ) {
			push @to_delete, $self->delete_upload($i);
			
			# For each thumbnail:
			for my $thumb (@{ $imgs->{$i}->{thumbs} }) {
				push @to_delete, $self->delete_upload($thumb->{name});
			}
		}

	}
	return @to_delete;
}

=head2 delete_upload()

 # Provide the file upload field name
 my $field_name = $u->delete_upload('img_1');

 # And optionally the ID
 my $field_name = $u->delete_upload('img_1', 14 );

This method is used to delete a row in the uploads table and file system file associated
with a single upload.  Usually it's more convenient to use C<delete_checked_uploads>
than to call this method directly.

If the ID is not provided, the value of a form field named
C<$file_field.'_id'> will be used. C<$file_name> is the field
name or thumbnail name defined in the C<spec>.

The method returns the field name deleted, with "_id" included. 

=cut

sub delete_upload {
	my $self = shift;
    my ($file_field,$id) = @_;

    my $q = $self->{query};

	unless ($id) {
		# before we delete anything with it, verify it's an integer.
        $q->param($file_field.'_id') =~ /(^\d+$)/ 
			|| die "no id for upload named $file_field";
		$id = $1;
	}

    $self->delete_file($id);
    $self->delete_meta($id);

	# return field name to delete
	return $file_field.'_id';
}

=head2 fk_meta()

 my $href = $u->fk_meta($table,\%where,@prefixes);

Returns a hash reference of information about the file, useful for 
passing to a templating system. Here's an example of what the contents 
of C<$href> might look like:

 {
     file_1_id     => 523,
     file_1_url    => 'http://localhost/images/uploads/523.pdf',
 }

If the files happen to be images and have their width and height
defined in the database row, template variables will be made
for these as well. 

Here's an example syntax of calling the function:

 my $href = $u->fk_meta('news',{ item_id => 23 },qw/file_1/);

This is going to fetch the file information from the upload table for using the row 
where news.item_id = 23 AND news.file_1_id = uploads.upload_id.

This is going to fetch the file information from the upload table for using the row 
where news.item_id = 23 AND news.file_1_id = uploads.upload_id.

The C<%where> hash mentioned here is a L<SQL::Abstract|SQL::Abstract> where clause. The
complete SQL that used to fetch the data will be built like this:

 SELECT upload_id as id,width,height,extension 
    FROM uploads, $table 
    WHERE (upload_id = ${prefix}_id AND (%where_clause_expanded here));

=cut 
	
sub fk_meta {
    my $self = shift;
    my %p = validate(@_,{
        table    => { type => SCALAR },
        where    => { type => HASHREF },
        prefixes => { type => ARRAYREF },
        prevent_browser_caching => { default => 1 }
    });


	my $table = $p{table};
	my $where = $p{where};
	my @file_fields = @{ $p{prefixes} };

	my $DBH = $self->{dbh};
	my %fields;
	require SQL::Abstract;
	my $sql = SQL::Abstract->new;
	my ($stmt,@bind) = $sql->where($where);
	
	# We don't want the 'WHERE' word that SQL::Abstract adds
	$stmt =~ s/^\s?WHERE//;


	# XXX There is probably a more efficient way to get this data than using N selects

    # mysql uses non-standard quoting
	my $qt = ($DBH->{Driver}->{Name} eq 'mysql') ? '`' : '"'; 

    my $map = $self->{up_table_map};

	for my $field (@file_fields) {
		my $upload = $DBH->selectrow_hashref(qq!
			SELECT * 
				FROM !.$self->{up_table}.qq!, $table AS t
				WHERE ($map->{upload_id} = t.${qt}${field}_id${qt} and ($stmt) )!,
				{},@bind);

            my %upload_fields = $self->transform_meta(
                meta => $upload,
                prevent_browser_caching => $p{prevent_browser_caching},
                prefix => $field,
            );
           %fields = (%fields, %upload_fields);

	}

	return \%fields;
}

=head2 names

Returns an array of all the upload names, including any thumbnail names.

=cut

sub names {
	my $self = shift;
	my $imgs = $self->{spec};

	return keys %$imgs,  # primary images
		map { map { $_->{name}   } @{ $$imgs{$_}->{thumbs} } } keys %$imgs;  # thumbs
}

=head1 METHODS FOR EXTENDING CGI::UPLOADER

These are methods that are used internally. You shouldn't need to use them
for most operations. However, if you are doing something more complex,
you may want to override one of these methods.

=head2 store_upload()

 my %entity_upload_extra = $u->store_upload(
    file_field    => $file_field,
    src_file      => $tmp_filename,
    uploaded_mt   => $uploaded_mt,
    file_name     => $file_name,
    shared_meta   => $shared_meta,  # optional
    id_to_update  => $id_to_update, # optional
 );

Does all the processing for a single upload, after it has been uploaded
to a temp file already.

It returns a hash of key/value pairs as described in L<store_uploads()>.

=cut

sub store_upload {
    my $self = shift;
    my %p = validate(@_, {
            file_field    => { type => SCALAR },
            src_file      => { type => SCALAR },
            uploaded_mt   => { type => SCALAR },
            file_name     => { type => SCALAR | GLOBREF },
            shared_meta   => { type => HASHREF | UNDEF,    default => {} },
            id_to_update  => { regex => qr/^\d*$/, optional => 1 },
        });

    my (
        $file_field,
        $tmp_filename,
        $uploaded_mt,
        $file_name,
        $shared_meta,
        $id_to_update,
    ) = ($p{file_field},$p{src_file},$p{uploaded_mt},$p{file_name},$p{shared_meta},$p{id_to_update});

    my $meta = $self->extract_meta($tmp_filename,$file_name,$uploaded_mt);

    # downsize primary image if needed
    my $downsize = $self->{spec}{$file_field}{downsize};
#use Data::Dumper;
#warn Dumper ($downsize,$meta);

    my ($curr_w, $curr_h) = imgsize($tmp_filename);
    if (
            (defined $downsize->{w} and $downsize->{w} < $curr_w) 
        or  (defined $downsize->{h} and $downsize->{h} < $curr_h) 
        ) {
         $tmp_filename  = $self->gen_thumb(
                filename => $tmp_filename,
                w => $downsize->{w},
                h => $downsize->{h},
            );
        }

        $meta = $self->extract_meta($tmp_filename,$file_name,$uploaded_mt);

        $shared_meta ||= {};
        my $all_meta = { %$meta, %$shared_meta };   

    my $id;
    # If it's an update
    if ($id = $id_to_update) {
        # delete old thumbnails before we create new ones
        $self->delete_thumbs($id);
    }

    # insert or update will be performed as approriate. 
    $id = $self->store_meta(
        $file_field, 
        $all_meta,
        $id );


    $self->store_file($file_field,$id,$meta->{extension},$tmp_filename);

    my %ids = $self->create_store_thumbs(
        $file_field,
        $all_meta,
        $tmp_filename,
        $id,
    );

    return (%ids, $file_field.'_id' => $id);

}
 

=head2 extract_meta() 

 $self->extract_meta($file_field)

This method extracts and returns the meta data about a file and returns it.

Input: A file field name.

Returns: a hash reference of meta data, following this example:

 {
         mime_type => 'image/gif',
         extension => '.gif',
         bytes     => 60234,
 
         # only for images
         width     => 50,
         height    => 50,
 }

=cut 

sub extract_meta {
    validate_pos(@_,1,1,1,0);
    my $self = shift;
    my $tmp_filename = shift;
    my $file_name = shift;
    my $uploaded_mt = shift || '';

    


   require File::MMagic;	
   my $mm = File::MMagic->new; 

   my $fm_mt = $mm->checktype_filename($tmp_filename);

   # If File::MMagic didn't find a mime_type, we'll use the uploaded one.
   my $mt = ($fm_mt || $uploaded_mt);
   assert($mt,'found mime type');


   use MIME::Types;
   my $mimetypes = MIME::Types->new;
   my MIME::Type $t = $mimetypes->type($mt);
   my @mt_exts = $t ? $t->extensions : undef;

   my $ext;

   # figure out an extension
   my ($uploaded_ext) = ($file_name =~ m/\.([\w\d]*)?$/);

   # If there is at least one MIME-type found
   if ($mt_exts[0]) {
   		# If the upload extension is one recognized by MIME::Type, use it.
		if (grep {/^$uploaded_ext$/} @mt_exts) 	 {
			$ext = $uploaded_ext;
		}
		# otherwise, use one from MIME::Type, just to be safe
		else {
			$ext = $mt_exts[0];
		}
   }
   else {
   	   # If is a provided extension but no MIME::Type extension, use that.
	   # It's possible that there no extension uploaded or found)
	   $ext = $uploaded_ext;
   }

   if ($ext) {
        $ext = ".$ext" if $ext;
   }
   else {
	   die "no extension found for file name: $file_name";
   }


   # Now get the image dimensions if it's an image 
    my ($width,$height) = imgsize($tmp_filename);

    return { 
        mime_type => $mt, 
        extension => $ext,
        bytes     => (stat ($tmp_filename))[7],

        # only for images
        width     => $width,
        height    => $height,
    };
    

}

=head2 store_meta()

 my $id = $self->store_meta($file_field,$meta);  

This function is used to store the meta data of a file upload.

Input: 
 - file field name
 - A hashref of key/value pairs to be store. Only the key names defined by
the C<up_table_map> in C<new()> will be used. Other values in the hash will be
ignored.
 - Optionally, an upload ID can be passed, causing an 'Update' to happen instead of an 'Insert' 

Output:
  - The id of the file stored. The id is generated by store_meta(). 

=cut

sub store_meta {
    validate_pos(@_,1,1,1,0);
	my $self = shift;

    # Right now we don't use the the file field name
    # It seems like a good idea to have in case you want to sub-class it, though. 
    my $file_field  = shift;
	my $href = shift;
	my $id = shift;

	my $DBH = $self->{dbh};

	require SQL::Abstract;
	my $sql = SQL::Abstract->new;
    my $map = $self->{up_table_map};
    my %copy = %$href;

    my $is_update = 1 if $id;

    if (!$is_update && $self->{db_driver} eq 'Pg') {
        $id = $DBH->selectrow_array("SELECT NEXTVAL('".$self->{up_seq}."')");
        $copy{upload_id} = $id;
    }

    my @orig_keys = keys %copy;
    for (@orig_keys) {
        if (exists $map->{$_}) {
            # We're done if the names are the same
            next if ($_ eq $map->{$_});

            # Replace each key name with the mapped name
            $copy{ $map->{$_} } = $copy{$_};

        }
        # The original field is now duplicated in the hash or unknown.
        # delete in either case. 
        delete $copy{$_};
    }

    my ($stmt,@bind); 
    if ($is_update) {
     ($stmt,@bind)   = $sql->update($self->{up_table},\%copy, { $map->{upload_id} => $id });
    }
    else {
     ($stmt,@bind)   = $sql->insert($self->{up_table},\%copy);
    }

    $DBH->do($stmt,{},@bind);
    if (!$is_update && $self->{db_driver} eq 'mysql') {
        $id = $DBH->{'mysql_insertid'};
    }

	return $id;
}

=head2 create_store_thumbs() 

 my %thumb_ids = $self->create_store_thumbs(
                         $file_field,
                         $meta_href,
                         $tmp_filename,
						 $thumbnail_of_id,
                        );

This method is responsible for creating and storing 
any needed thumnbnails.

Input:
 - file field name
 - a hash ref of meta data, as C<extract_meta> would produce 
 - path to temporary file of the file upload
 - ID of upload that thumbnails will be made from

=cut

sub create_store_thumbs {
	validate_pos(@_,
        1,                   # $self
		{ type => SCALAR  }, # $file_field
		{ type => HASHREF }, # $meta
		{ type => SCALAR  }, # $tmp_filename
		{ type => SCALAR  }, # $thumbnail_of_id
	);
	my $self = shift;
	my $file_field = shift;
	my $meta = shift;
    my $tmp_filename = shift;
	my $thumbnail_of_id  = shift;

	my $thumbs = $self->{spec}{$file_field}{thumbs};
	my $q = $self->{query};
	my %out;

	my ($w,$h) = ($meta->{width},$meta->{height});
	for my $thumb (@$thumbs) {
        my $thumb_tmp_filename;
		# resize as needed
		if ((defined $w and defined $h) and ($w > $thumb->{w} or $h > $thumb->{h})) {
            $thumb_tmp_filename = $self->gen_thumb(
                filename => $tmp_filename,
                w => $thumb->{w},
                h => $thumb->{h});
		}
        # If the file is already reasonably sized, just use theh original tmp filename
        else {
            $thumb_tmp_filename = $tmp_filename;
        }

		# inherit mime-type and extension from parent
		# set as thumbnail of parent
		my %t_info =  (%$meta, thumbnail_of_id => $thumbnail_of_id);
		($t_info{width}, $t_info{height}) = imgsize($thumb_tmp_filename);

		# Insert		
		my $id = $self->store_meta($thumb->{name}, \%t_info );

		# Add to output hash
		$out{$thumb->{name}.'_id'} = $id;

        $self->store_file($thumb->{name},$id,$t_info{extension},$thumb_tmp_filename);
	}
	return %out;
}

=head2 upload()

The function is responsible for actually uploading the file.

Input: 
 - file field name

Output:
 - temporary file name
 - Uploaded MIME Type
 - Name of uploaded file (The value of the file form field)

Currently CGI.pm and CGI::Simple are supported. 

=cut 

sub upload {
    my $self = shift;
    my $file_field = shift;

   my $q = $self->{query};

   my $fh;	
   my $mt = '';
   my $filename = $q->param($file_field);

   if ($q->isa('CGI::Simple') ) {
	   $fh = $q->upload($filename); 
	   $mt = $q->upload_info($filename, 'mime' );

	   if (!$fh && $q->cgi_error) {
		   warn $q->cgi_error && return undef;
	   }
   }
   elsif ( $q->isa('Apache::Request') ) {
	    my $upload = $q->upload($file_field);
		$fh = $upload->fh;
		$mt = $upload->type;
   }
   # default to CGI.pm behavior
   else {
	   $fh = $q->upload($file_field);
	   $mt = $q->uploadInfo($fh)->{'Content-Type'} if $q->uploadInfo($fh);

	   if (!$fh && $q->cgi_error) {
		   warn $q->cgi_error && return undef;
	   }
   }

   return undef unless ($fh && $filename);
   #assert($fh, 		'have upload file handle');
   #assert($filename,'have upload file name');


   my ($tmp_fh, $tmp_filename) = tempfile('CGIuploaderXXXXX', UNLINK => 1);
   binmode($tmp_fh);

   require File::Copy;
   import  File::Copy;
   copy($fh,$tmp_filename) || die "upload: unable to create tmp file: $!";

    return ($tmp_filename,$mt,$filename);
} 

=head2 delete_meta()

 my $dbi_rv = $self->delete_meta($id);

Deletes the meta data for a file and returns the DBI return value for this operation.

=cut

sub delete_meta {
    validate_pos(@_,1,1);
    my $self = shift;
    my $id = shift;

	my $DBH = $self->{dbh};
    my $map = $self->{up_table_map};

   return $DBH->do("DELETE from ".$self->{up_table}." WHERE $map->{upload_id} = $id");

}

=head2 delete_file()

 $self->delete_file($id);

Call from within C<delete_upload>, this routine deletes the actual file.
Dont' delete the the meta data first, you may need it build the path name
of the file to delete.

=cut

sub delete_file {
    validate_pos(@_,1,1);
    my $self = shift;
    my $id   = shift;

    my $map = $self->{up_table_map};
    my $dbh = $self->{dbh};

    my $ext = $dbh->selectrow_array("
        SELECT $map->{extension}
            FROM $self->{up_table}
            WHERE $map->{upload_id} = ?",{},$id);
    $ext || die "found no extension in meta data for ID $id. Deleting file failed.";


    my $file = $self->{updir_path}.'/'.$self->build_loc($id,$ext);

    if (-e $file) {  
        unlink $file || die "couldn't delete upload  file: $file:  $!";
    }
    else {
        warn "file to delete not found: $file";
    }

}

=head2 delete_thumbs()

 $self->delete_thumbs($id);

Delete the thumbnails for a given file ID, from the file system and the database

=cut

sub delete_thumbs {
    validate_pos(@_,1,1);
    my ($self,$id) = @_;

    my $dbh = $self->{dbh};
    my $map = $self->{up_table_map};

    my $thumb_ids_aref = $dbh->selectcol_arrayref(
        "SELECT   $map->{upload_id} 
            FROM  ".$self->{up_table}. "
            WHERE $map->{thumbnail_of_id} = ?",{},$id) || [];

    for my $thumb_id (@$thumb_ids_aref) {
        $self->delete_file($thumb_id);
        $self->delete_meta($thumb_id);
    }

}


=head2 store_file()

 $self->store_file($file_field,$tmp_file,$id,$ext);

Stores an upload file or dies if there is an error.

Input:
  - file field name
  - path to tmp file for uploaded image
  - file id, as generated by C<store_meta()>
  - file extension, as discovered by C<extract_meta>

Output: none

=cut

sub store_file {
    validate_pos(@_,1,1,1,1,1);
    my $self = shift;
    my ($file_field,$id,$ext,$tmp_file) = @_;
	assert($ext, 'have extension');
	assert($id,'have id');
	assert(-f $tmp_file,'tmp file exists');

    require File::Copy;	
    import File::Copy;
    copy($tmp_file, File::Spec->catdir($self->{updir_path},$self->build_loc($id,$ext)) )
    || die "Unexpected error occured when uploading the image: $!";

}

=head2 build_loc()

 my $up_loc = $self->build_loc($id,$ext);

Builds a path to access a single upload, relative to C<updir_path>.  
This is used to both file-system and URL access. Also see the C<file_scheme> 
option to C<new()>, which affects it's behavior. 

=cut

sub build_loc {
    validate_pos(@_,1,1,1);
    my ($self,$id,$ext) = @_;

    my $scheme = $self->{file_scheme};

    my $loc;
    if ($scheme eq 'simple') {
        $loc = "$id$ext";
    }     
    elsif ($scheme eq 'md5') {
        require Digest::MD5;
        import Digest::MD5 qw/md5_hex/;
        my $md5_path = md5_hex($id);
        $md5_path =~ s|^(.)(.)(.).*|$1/$2/$3|;

        my $full_path = $self->{updir_path}.'/'.$md5_path;
        unless (-e $full_path) {
            mkpath($full_path);
        }

        $loc = "$md5_path/$id$ext";
    }
}

=head2 gen_thumb

 ($thumb_tmp_filename)  = $self->gen_thumb(
    filename => $orig_filename,
    w => $width,
    h => $height,
    );

This function creates a copy of given image file and resizes the copy to the
provided width and height.

Input:
    filename => filename of source image 
    w => max width of thumbnail
    h => max height of thumbnail

One or both  of C<w> or C<h> is required.

Output:
    - filename of generated tmp file for the thumbnail 

=cut

sub gen_thumb {
    my $self = shift;
    my %p = validate(@_,{
            filename => {type => SCALAR },
            w => { type => SCALAR | UNDEF, regex => qr/^\d*$/, optional => 1, },
            h => { type => SCALAR | UNDEF, regex => qr/^\d*$/, optional => 1 },
        });
    die "must supply 'w' or 'h'" unless (defined $p{w} or defined $p{h});


    my $orig_filename = $p{filename};
    my ($orig_w,$orig_h,$orig_fmt) = imgsize($orig_filename);

    my $target_h = $p{h};
    my $target_w = $p{w};

    $target_h = sprintf("%.1d", ($orig_h * $target_w) / $orig_w) unless $target_h;
    $target_w = sprintf("%.1d", ($orig_w * $target_h) / $orig_h) unless $target_w;

    my ($thumb_tmp_fh, $thumb_tmp_filename) = tempfile('CGIuploaderXXXXX', UNLINK => 1);
    binmode($thumb_tmp_fh);

    eval { require Image::Magick; };
    my $have_image_magick = !$@;
    eval { require GD; };
    my $have_gd = !$@; 

     my %gd_map = (
         'PNG' =>  'png',
         'JPG'  => 'jpeg',
         'GIF'  => 'gif',
     );

    if ($have_image_magick) {
        my $img = Image::Magick->new();
        $img->Read(filename=>$orig_filename);
        $img->Resize($target_w.'x'.$target_h); 
        my $err = $img->Write($thumb_tmp_filename);
        if ($err) {
            warn $err;
            my $code;
            # codes > 400 are fatal 
            die $err if ((($code) = $err =~ /(\d+)/) and ($code > 400));
        }
    }
    elsif ($have_gd and (grep {m/^$orig_fmt$/} keys %gd_map)) {
		die "Image::Magick wasn't found and GD support is not complete. 
			Install Image::Magick or fix GD support. ";

        # This formula was figured out by Ehren Nagel
        my ($actual_w,$actual_h) = ($target_w,$target_h);
        my $potential_w  = ($target_h/$orig_h)*$orig_w;
        my $potential_h  = ($target_w/$orig_w)*$orig_h;

        if  (($orig_h > $orig_w ) and ($potential_w < $target_w)) {
            $actual_w = $potential_w;
        }
        elsif (($orig_h > $orig_w ) and ($potential_w >= $target_w)) {
            $actual_h = $potential_h;
        }
        elsif (($orig_h <=  $orig_w ) and ($potential_h < $target_h ))   {
            $actual_h = $potential_h;
        }
        elsif (($orig_h <=  $orig_w ) and ($potential_h >= $target_h ))   {
            $actual_w = $potential_w;
        }

        my $orig  = GD::Image->new("$orig_filename") || die "$!";
        my $thumb = GD::Image->new( $actual_w,$actual_h );
        $thumb->copyResized($orig,0,0,0,0,$actual_w,$actual_h,$orig_w,$orig_h);
        my $meth = $gd_map{$orig_fmt};
        no strict 'refs';
        no strict 'subs';
        binmode($thumb_tmp_fh); 
        print $thumb_tmp_fh, $thumb->$meth;
    }
    else {
        die "No graphics module found for image resizing. Install Image::Magick or GD.
        ( GD is only good for  PNG and JPEG, but may be easier to get installed ): $@ "
    }

    assert ($thumb_tmp_filename, 'thumbnail tmp file created');
    return $thumb_tmp_filename;

}

# Documentation? 

sub transform_meta  {
    my $self = shift;
    my %p = validate(@_, {
        meta   => { type => HASHREF },
        prefix => { type => SCALAR  },
        prevent_browser_caching => { default => 1 },
        fields => { type => ARRAYREF ,
                    default => [qw/id url width height/], 
                },
        });

    my $map = $self->{up_table_map};

    my %result;

    my $qs;
    if ($p{prevent_browser_caching})  {
        # a random number to defeat image caching. We may want to change this later.
        my $rand = (int rand 100);
        $qs = "?$rand";
    }

    my %fields = map { $_ => 1 } @{ $p{fields} }; 

    if ($fields{url}) {
        $result{$p{prefix}.'_url'} = $self->{updir_url}.'/'.
            $self->build_loc($p{meta}{ $map->{upload_id}   },$p{meta}{extension}).$qs ;
        delete $fields{url};
    }

    if (exists $fields{id}) {
        $result{$p{prefix}.'_id'} = $p{meta}->{ $map->{upload_id} };
        delete $fields{id};
    }

    for my $k (keys %fields) {
        my $v = $p{meta}->{ $map->{$k} };
        $result{$p{prefix}.'_'.$k} = $v if defined $v;
    }

    return %result;


}

1;
__END__


=head1 AUTHOR

Mark Stosberg <mark@summersault.com>

=head1 THANKS

A special thanks to David Manura for his detailed and persistent feedback in 
the early days, when the documentation was wild and rough.

Barbie, for the first patch. 

=head1 LICENSE 

This program is free software; you can redistribute it and/or modify
it under the terms as Perl itself.
