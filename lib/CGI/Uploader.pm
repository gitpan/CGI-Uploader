package CGI::Uploader;

use 5.005;
use strict;
use CGI::Carp;
use Params::Validate qw/:all/;
require Exporter;
use vars qw($VERSION);

$VERSION = '0.61_02';

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

=head1 EXAMPLE SETUP

Here's a simple form that could be used with this module to maintain
a photo address book on the web.  The user inputs a name and uploads 
a photo. This gets stored on the server and a thumbnail is automatically
generated from the picture and saved as well. The files can then be
downloaded from given URLs.

=head2 EXAMPLE FORM

 <form enctype="multipart/form-data">
    Friend Name: <input type="text" name="full_name"> <br />
    Image: <input type="file" name="photo">
    <input type="submit">
 </form>

Notice that the 'enctype' is important for file uploads to work.

So we have a text field for a 'full_name' and a file upload field named
'photo'.  

=head2 EXAMPLE DATABASE 

To continue with the example above, we'll define two tables, one 
will store file upload meta data. This can be used to store the information
about file uploads related to any number of tables. However, only one other 
table is required. (Future versions may not require an additional table at all.) 

For our example, we'll create an table to hold names and photos of friends:

	-- Note the Postgres specific syntax here
    CREATE SEQUENCE upload_id_seq;
	CREATE TABLE uploads (
		upload_id   int primary key not null 
		                default nextval('upload_id_seq'),
		mime_type   character varying(64),
		extension   character varying(8), -- file extension
		width       integer,                 
		height      integer
	)

 CREATE TABLE address_book (
    friend_id       int primary key,
    full_name       varchar(64),

    -- these two reference uploads('upload_id'),
    photo_id            int,  
    photo_thumbnail_id  int 
 );
    
I<MySQL> is also supported. Check in the distribution for sample SQL 'Create'
scripts for both I<MySQL> and I<Postgresql> databases.>.

=head2 EXAMPLE FORM VALIDATION

Although it is not required, this module is designed to work with
L<Data::FormValidator|Data::FormValidator>, which can provide sophisticated
validation of file uploads. The Data::FormValidator profile to validate the
above form might look like this:

 {
    validator_packages => [qw(Data::FormValidator::Constraints::Upload)],
    required => [qw/full_name photo/],
           constraints => {
               photo => [
                   {   
                       constraint_method => 'file_format',
                       params => [{
                            mime_types => [qw!image/jpeg image/png!],
                        }],
                   },
                   {   
                       constraint_method => 'file_max_bytes',
                       params => [\1000],
                   },
                   {   
                       constraint_method => 'image_max_dimensions',
                       params => [\200,\200],
                   },

            ],
     }
 }

=head2 EXAMPLE RESULT

Here's our end result: 

 address_book table:
  
 friend_id | full_name | photo_id | photo_thumbnail_id 
 -----------------------------------------------------
 2         | M. Lewis  |        3 |                 4 


 uploads table:

 upload_id | mime_type | extension | width | height |
 ----------------------------------------------------
 3         | image/png | .png      |  200  | 400   |    
 4         | image/png | .png      |   50  | 100    |    

The files are stored on the file system. '4.png' was generated on
the server a thumbnail of 3.png.

 /home/friends/www/uploads/3.png
 /home/friends/www/uploads/4.png


=head2 EXAMPLE CODE

To accomplish something like the above, we first need to provide a upload
specification. This declares all the file form upload fields we will use, as
well as details of the thumbnails we will create based on these. 

These names need to be identical to the database column names that refer to
these images, with one difference. In the database, '_id' needs to be added to
the end of the name. So a form field named 'photo' is referenced a database
column of 'photo_id'.

 # The same object can be used when inserting, updating, deleting 
 # and selecting the uploads.

 my $u = CGI::Uploader->new(
 	spec => {
        photo => [
            { name => 'photo_thumbnail', w => 100, h => 100, }
        ],
    }

 	updir_url  => 'http://localhost/uploads',
 	updir_path => '/home/friends/www/uploads',
 	dbh	       => $dbh,	

 );

 # get $form_data straight from the CGI environment
 # (For the real world, I recommend validation with Data::FormValidator) 
 my $form_data = $q->Vars; 

 my $friend = $u->store_uploads($form_data);

 # Now the $friend hash been transformed so it can easily inserted
 # It now looks like this:
 # {
 #    full_name => 'M. Lewis',
 #    photo_id => 3,
 #    photo_thumbnail_id => 4,
 # }

 # I like to use SQL::Abstract for easy inserts.

 use SQL::Abstract;
 my $sql = SQL::Abstract->new;
 my($stmt, @bind) = $sql->insert('address_book',$friend);
 $dbh->do($stmt,{},@bind);


That's a basic example. Read on for more details about what's possible,
including convenient functions to also help with updating, deleting, and 
linking to the upload.

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
SQL table, and those that CGI::Uploader uses . The keys are the CGI::Uploader 
default names. Values are the names that are actually used in your table.

This is not required. It simply allows you to use custom column names.

  upload_id  => 'upload_id',
  mime_type  => 'mime_type',
  extension  => 'extension',
  width      => 'width',
  height     => 'height',   

You may also define additional column names with a value of 'undef'. This feature
is only useful if you override the C<extract_meta()> method. Values for these additional
columns will then be stored by C<store_meta()> and retrieved with C<meta_hashref()>.

=item up_seq

For Postgres only, the name of a sequence used to generate the upload_ids.
Defaults to C<upload_id_seq> if omitted.

=item

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
                              upload_id  => 'upload_id',
                              mime_type  => 'mime_type',
                              extension  => 'extension',
                              width      => 'width',
                              height     => 'height',   
#                              bytes      => 'bytes',
                          }
        },
		up_seq      => { default=> 'upload_id_seq'},
		spec        => { type => HASHREF },
		query	    => 0,
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

=cut 

sub store_uploads {
	validate_pos(@_,1,1);
	my $self      = shift;
	my $form_data = shift;
	my $uploads = $self->{spec};

	my (%add_to_valid);
	my $q = $self->{query};

	for my $file_field (keys %$uploads) {
        # If we have an uploaded file for this

        if (my ($tmp_filename,$uploaded_mt,$file_name) = $self->upload($file_field) ) {
            my $meta = $self->extract_meta($tmp_filename,$file_name,$uploaded_mt);

            my $custom_meta = $self->custom_meta($file_field,$meta) || {};

            my %ids = $self->create_store_thumbs(
                    $file_field,
                    $meta,

                );
			%add_to_valid = (%add_to_valid, %ids);

            my $id = $self->store_meta($file_field, {%$meta, %$custom_meta} );
			
			$add_to_valid{$file_field.'_id'} = $id;

            $self->store_file($file_field,$id,$meta->{extension},$tmp_filename);
			
		}
	}

	# Now add and delete as needed
	my $entity = { %$form_data, %add_to_valid };
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

    $self->delete_file($file_field,$id);
    $self->delete_meta($id);

	# return field name to delete
	return $file_field.'_id';
}

=head2 meta_hashref()

 my $href = $u->meta_hashref($table,\%where,@prefixes);

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

 my $href = $u->meta_hashref('news',{ item_id => 23 },qw/file_1/);

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
	
sub meta_hashref {
	validate_pos(@_,1,
		{ type => SCALAR },
		{ type => HASHREF },
		(0) x (@_ - 3) );
	my $self = shift;
	my $table = shift; 
	my $where = shift;
	my @file_fields = @_;
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
    my $fields_sql = " $map->{upload_id} AS id \n"; 
    for (keys %$map) {
        next if ($_ eq 'upload_id');
        $fields_sql .= ", $map->{$_} AS $_\n";
    }

	# make a random number available to defeat image caching.
	my $rand = (int rand 100);

	for my $field (@file_fields) {
		my $upload = $DBH->selectrow_hashref(qq!
			SELECT $fields_sql 
				FROM !.$self->{up_table}.qq!, $table AS t
				WHERE ($map->{upload_id} = t.${qt}${field}_id${qt} and ($stmt) )!,
				{},@bind);

		if ($upload->{id}) {
			$fields{$field.'_url'} = $self->{updir_url}.'/'.$self->build_loc($field,$upload->{id},$upload->{extension})."?$rand";

            # The id needs to be handled explicitly, because the loop below will miss it.
            $fields{$field.'_id'} = $upload->{id}; 

			for my $k (keys %$map) {
				$fields{$field.'_'.$k} = $upload->{$k} if defined $upload->{$k};
			}
		}
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

=head1 SUB-CLASS AND OVERRIDE METHODS

CGI::Uploader implements some methods which are expected to be overridden by
implementing them in a sub-class module. These methods are as follows:

=head2 custom_meta()

 sub custom_meta {
    my ($self,$file_field,$meta) = @_;

    my $q   = $self->{query};
    my $dbh = $self->{dbh};

    my $custom_meta;
    # ...
    return $custom_meta;
 }

 my $meta = $self->custom_meta($file_field,$meta)

This method is used to store additional meta data about your file upload besides
what is automatically discovered with C<extract_meta()>. For example, you 
might want to store a title and description of the file. 

Input:
  - the file field name. This is the file field name or thumbnail name given 
    in the C<spec>.
  - hashref of extracted meta data. They keys are: 
    C<mime_type> and C<extension>. Images will also have C<width>, and C<height>.

Output:
  - A hashref of your custom meta data.

There is no need to repeat the input keys in the hashref you return.
However, if you do include one of the existing keys, your value
will override the original. Each key must correspond to a key
in C<up_table_map>. Otherwise it will be ignored.

You may find the L<CGI::Expand> module here. It makes it easy to  
generate a hash ref from a group of CGI parameters which all
have the same prefix. 

=cut

sub custom_meta {
    my ($self,$file_field,$meta) = @_;
    my $custom_meta = {};
    # ...
    return $custom_meta;
}

=head1 METHODS FOR EXTENDING CGI::UPLOADER

These are methods that are used internally. You shouldn't need to use them
for most operations. However, if you are doing something more complex,
you may want to override one of these methods.

=head2 extract_meta(file_field) 

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

   # figure out an extension
   my ($uploaded_ext) = ($file_name =~ m/\.([\w\d]*)?$/);

   require File::MMagic;	
   my $mm = File::MMagic->new; 


   my $fm_mt = $mm->checktype_filename($tmp_filename);

   # If File::MMagic didn't find a mime_type, we'll use the uploaded one.
   my $mt = ($fm_mt || $uploaded_mt);

   use MIME::Types;
   my $mimetypes = MIME::Types->new;
   my MIME::Type $t = $mimetypes->type($mt);
   my @mt_exts = $t->extensions;

   my $ext;
   if (scalar @mt_exts) {
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


   # Now get the image dimensions if it's an image 
	require Image::Magick;
	my $img = Image::Magick->new();
	my $err = $img->Read(filename=>$tmp_filename);


    my ($width,$height) = $img->Get('width','height');

    return { 
        mime_type => $mt, 
        extension => ".$ext" ,
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

Output:
  - The id of the file stored. The id is generated by store_meta(). 

=cut

sub store_meta {
    validate_pos(@_,1,1,1);
	my $self = shift;

    # Right now we don't use the the file field name
    # It seems like a good idea to have in case you want to sub-class it, though. 
    my $file_field  = shift;
	my $href = shift;

	my $DBH = $self->{dbh};

	require SQL::Abstract;
	my $sql = SQL::Abstract->new;
	my $id;
    my $map = $self->{up_table_map};

    my %copy = %$href;

    if ($self->{db_driver} eq 'Pg') {
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

    my ($stmt,@bind) = $sql->insert($self->{up_table},\%copy);

    $DBH->do($stmt,{},@bind);
    if ($self->{db_driver} eq 'mysql') {
        $id = $DBH->{'mysql_insertid'};
    }

	return $id;
}

=head2 create_store_thumbs() 

 my %thumb_ids = $self->create_store_thumbs(
                         $file_field,
                         $meta_href,
                        );

This method is responsible for creating and storing 
any needed thumnbnails.

Input:
 - file field name
 - a hash ref of meta data, as C<extract_meta> would produce 


=cut

sub create_store_thumbs {
	validate_pos(@_,
        1,                    # $self
		{ type => SCALAR  },  # $file_field
		{ type => HASHREF  },   # $info 
	);
	my $self = shift;
	my $file_field = shift;
	my $info = shift;

	my $thumbs = $self->{spec}{$file_field}{thumbs};
	my $q = $self->{query};
	my %out;

	require Image::Magick;
	my $img = Image::Magick->new();

	$img->Read(filename=>$q->tmpFileName($q->param($file_field)));

	my ($w,$h) = ($info->{width},$info->{height});
	for my $thumb (@$thumbs) {
		# resize as needed
		if ((defined $w and defined $h) and ($w > $thumb->{w} or $h > $thumb->{h})) {
			$img->Resize($thumb->{w}.'x'.$thumb->{h}); 
		}

		# inherit mime-type and extension from parent
		my %t_info =  %$info;
		($t_info{width}, 
			$t_info{height}) = $img->Get('width','height');

        my $custom_meta = $self->custom_meta($thumb->{name},\%t_info) || {};

		# Insert		
		my $id = $self->store_meta($thumb->{name}, {%t_info, %$custom_meta });

		# Add to output hash
		$out{$thumb->{name}.'_id'} = $id;

        my $err = $self->store_thumb($thumb->{name},$id,$t_info{extension},$img,);
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

=head2 upload()

The function is responsible for actually uploading the file.

Input: 
 - file field name

Output:
 - temporary file name
 - Uploaded MIME Type
 - Name of uploaded file (The value of the file form field)

=cut 

sub upload {
    my $self = shift;
    my $file_field = shift;

   my $q = $self->{query};
   my $fh = $q->upload($file_field);
   if (!$fh && $q->cgi_error) {
   		warn $q->cgi_error && return undef;
	}

   my $mt = '';
   $mt = $q->uploadInfo($fh)->{'Content-Type'} if $q->uploadInfo($fh);

   my $filename = $q->param($file_field);

   # We could rely on the tmp file created by CGI.pm, but instead we create our own.
   use File::Temp qw/tempfile/;
   my ($tmp_fh, $tmp_filename) = tempfile('CGIuploaderXXXXX', UNLINK => 1);

   require File::Copy;
   import  File::Copy;
   copy($fh,$tmp_filename);

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
    validate_pos(@_,1,1,1);
    my $self = shift;
    my $file_field = shift;
    my $id   = shift;

    my $map = $self->{up_table_map};
    my $dbh = $self->{dbh};

    my $ext = $dbh->selectrow_array("
        SELECT $map->{extension}
            FROM $self->{up_table}
            WHERE $map->{upload_id} = ?",{},$id);
    $ext || die "found no extension in meta data for $file_field. Deleting file failed.";

    my $file = $self->{updir_path}.'/'.$self->build_loc($file_field,$id,$ext);

    if (-e $file) {  
        unlink $file || die "couldn't delete upload  file: $file:  $!";
    }
    else {
        warn "file to delete not found: $file";
    }

}

=head2 store_thumb()

Currently requires an Image::Magick object. API subject to change.
(So I'm not documenting the interface now. :)

=cut

sub store_thumb {
    my $self = shift;
    my ($file_name,$id,$ext,$img) = @_;

    my $loc = $self->build_loc($file_name,$id,$ext);
    my $err = $img->Write($self->{updir_path}.'/'.$loc);
    return $err;
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

    my $q = $self->{query};
    
    require File::Copy;	
    import File::Copy;

    copy($tmp_file, $self->{updir_path}."/". $self->build_loc($file_field,$id,$ext) )
    || die 'Unexpected error occured when uploading the image.';

}

=head2 build_loc()

 my $up_loc = $self->build_loc($file_field,$id,$ext);

Builds a path to access a single upload, relative to C<updir_path>.  
This is used to both file-system and URL access.

=cut

sub build_loc {
    validate_pos(@_,1,1,1,1);
    my ($self,$file_field,$id,$ext) = @_;

    # We don't use $file_field, but a sub-class might want it.

    return  "$id$ext";

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
