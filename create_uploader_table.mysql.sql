CREATE TABLE uploads (
	upload_id	int AUTO_INCREMENT primary key not null,
	mime_type  character varying(64),
	extension  character varying(8), -- file extension
	width      integer,                 
	height     integer
)
