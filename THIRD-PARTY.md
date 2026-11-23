# Third-party software

The app bundle includes **ExifTool** by Phil Harvey (https://exiftool.org), used to write XMP metadata.
ExifTool is free software; you can redistribute it and/or modify it under the same terms as Perl itself
(the Artistic License or the GNU General Public License). Pitpick runs it as a separate program and does not modify it.

The Apple Silicon part of the app includes **libjpeg-turbo** 3.2.1 (https://libjpeg-turbo.org), used to decode the
camera's embedded JPEG on several cores at once. It is covered by the IJG License, the Modified (3-clause) BSD License
and the zlib License; the full text is in `vendor/libjpeg-turbo/LICENSE.md` and `vendor/libjpeg-turbo/README.ijg`.
This software is based in part on the work of the Independent JPEG Group.

Screenshots in `docs/` show concert photos by Wouter Vellekoop (all rights reserved; not covered by the MIT license).
