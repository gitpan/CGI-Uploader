CREATE SEQUENCE upload_id_seq;
CREATE TABLE uploads (
	upload_id   int primary key not null default nextval('upload_id_seq'),
	mime_type  character varying(64),
	extension  character varying(8), -- file extension
	width      integer,                 
	height     integer
)
