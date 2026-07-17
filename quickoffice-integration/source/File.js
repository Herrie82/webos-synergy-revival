/*global console, enyo, File, $L */

/**
 * @fileoverview This file contains the implementation of the File kind
 *
 * @author <a href="mailto:m.rose@hp.com">Mike Rose</a>
 * @version 1.0
 */


/**
 * Representation of a file system object (file or folder). File objects are designed to be immutable.
 *
 * NOTE: File must be included before any associated view handlers in the depends.js file.
 */
enyo.kind({
    name: "File",
    kind: "Component",

    published: {
        /**
         * {String} The file extension, without the leading period, e.g. "doc". For folders, this
         *          field is always an empty string. For a downloaded remote file, this property
         *          will contain the extension of the <em>temporary</em> (local) file.
         */
        extension: undefined,
        /**
         * {String} For a downloaded remote file, this property will contain the extension of the
         *          original remote file (for display purposes). For local files, this property is
         *          identical to 'extension'.
         */
        extensionDisplay: undefined,
        /**
         * {String} The (generated) filename and extension, e.g. "My <new & improved> design.doc".
         *          For a downloaded remote file, this property will contain the filename of the
         *          <em>temporary</em> (local) file.
         */
        filename: undefined,
        /**
         * {String} For a downloaded remote file, this property will contain the filename of the
         *          original remote file (for display purposes). For local files, this property is
         *          identical to 'filename'.
         */
        filenameDisplay: undefined,
        /** {String} File name without extension, e.g. "My <new & improved> design" */
        fileStem: undefined,
        /**
         * {String} For a downloaded remote file, this property will contain the file stem of the
         *          original remote file (for display purposes). For local files, this property is
         *          identical to 'fileStem'.
         */
        fileStemDisplay: undefined,
        /** {String} A relative path to the icon file representing this file system object */
        iconPath: undefined,
        /** {String} A string representing the mimetype of this file */
        mimeType: undefined,
        /** {String} Full URI/path of the file or folder. */
        uri: undefined,
        /** {Number} Size of file, in bytes. */
        size: undefined,
        /** {String} The size of the file, formatted and localized, e.g. "0.98 GB". Generated on demand. */
        sizeFormatted: undefined,
        /** {Date} The file modification date and time. */
        timestamp: undefined,
        /** {String} The file modification time and/or date, formatted and localized, e.g. "May 10 1:49 AM". Generated on demand. */
        timestampFormatted: undefined,
        /** {Number} One of the <tt>File.kFILETYPE_</tt>* constants. Generated from extension for files. Must be set for folders. */
        type: undefined
    },

    statics: {
        kONE_DAY_IN_MILLIS: 1000 * 60 * 60 * 24,

        kONE_KILOBYTE: 1024,
        kONE_MEGABYTE: 1024 * 1024,
        kONE_GIGABYTE: 1024 * 1024 * 1024,

        // Threshold (in bytes) at which file size displays in KB instead of bytes.
        kKB_THRESHOLD: 1024,

        // Threshold (in KB) at which file size displays in MB instead of KB. Note that this value
        // accounts for a single-digit precision (i.e. 0.n) in the KB display. If the KB precision is
        // changed, this value must also change.
        kMB_THRESHOLD: 999.95,

        // Threshold (in MB) at which file size displays in GB instead of MB. Note that this value
        // accounts for a double-digit precision (i.e. 0.nn) in the MB display. If the MB precision is
        // changed, this value must also change.
        kGB_THRESHOLD: 999.995,

        // File type constants
        kFILETYPE_UNK: 0, // Unknown
        kFILETYPE_DIR: 1, // Directory/Folder
        kFILETYPE_DOC: 2, // MS Word Document
        kFILETYPE_PDF: 3, // Adobe PDF
        kFILETYPE_PPT: 4, // MS Powerpoint
        kFILETYPE_TXT: 5, // ASCII Text
        kFILETYPE_XLS: 6, // MS Excel

        // Type Filter ('Show') constants
        kFILTER_DOC: 0x01, // MS Word document and ASCII text
        kFILTER_PDF: 0x02, // Adobe PDF
        kFILTER_PPT: 0x04, // MS Powerpoint
        kFILTER_XLS: 0x08, // MS Excel
        kFILTER_SUP: ((enyo.fetchAppInfo().id === 'com.quickoffice.webos' || enyo.fetchAppInfo().id === 'com.quickoffice.browser') && 
                      !enyo.fetchAppInfo().version.match(/^1\.\d+\.\d+$/)) ? 0x7f : 0x7b, // Supported file types (not including Unknown)
        kFILTER_ALL: 0xff, // All files (including Unknown types)

        // Create the templates for displaying file size
        kTEMPLATE_BYTES: new enyo.g11n.Template($L("#{size} bytes")),
        kTEMPLATE_KILOBYTES: new enyo.g11n.Template($L("#{size} KB")),
        kTEMPLATE_MEGABYTES: new enyo.g11n.Template($L("#{size} MB")),
        kTEMPLATE_GIGABYTES: new enyo.g11n.Template($L("#{size} GB")),

        // File size formats
        // TODO: Modify these to suppress trailing zeros as that behavior becomes available.
        kFORMAT_BYTES: new enyo.g11n.NumberFmt({
            fractionDigits: 0
        }),

        kFORMAT_KILOBYTES: new enyo.g11n.NumberFmt({
            fractionDigits: 1
        }),

        kFORMAT_MEGABYTES: new enyo.g11n.NumberFmt({
            fractionDigits: 2
        }),

        kFORMAT_GIGABYTES: new enyo.g11n.NumberFmt({
            fractionDigits: 2
        }),

        // File timestamp formats
        kFORMAT_TODAY: new enyo.g11n.DateFmt({
            time: "short"
        }),

        kFORMAT_LAST_7_DAYS: new enyo.g11n.DateFmt({
            date: "long",
            dateComponents: "dm",
            weekday: "long",
            time: "short"
        }),

        kFORMAT_THIS_YEAR: new enyo.g11n.DateFmt({
            date: "long",
            dateComponents: "dm",
            time: "short"
        }),

        kFORMAT_OTHER_YEAR: new enyo.g11n.DateFmt({
            format: "short"
        }),

        // Single localized full date+time used for ALL file rows (see getTimestampFormatted).
        // date:"medium" gives an abbreviated month name; dateComponents:"dmy" forces day+month+
        // year in the locale's order; time:"short" honours the system 12/24h preference.
        kFORMAT_ALWAYS: new enyo.g11n.DateFmt({
            date: "medium",
            dateComponents: "dmy",
            time: "short"
        }),

        /** Today's date, used in formatting file dates. This can be refreshed by clients. */
        today: new Date(),

        /** A map of types to file kind strings, e.g. this.handlers[File.kFILETYPE_PDF] = "PdfView" */
        handlers: {},

        /**
         *
         * @param {Object} inType
         * @param {Object} inKind
         */
        registerAsTypeHandler: function(inType, inKind) {
            if (File.handlers[inType]) {
                console.warn("Multiple handlers specified for: " + inType);
            }
            File.handlers[inType] = inKind;
        },

        /**
         * Extracts the filename from the specified URI/path.
         *
         * @param {String} inUri A string containing the a filename with or without path
         *                       information, e.g. "/media/internal/foobar.xls" or "foobar.xls".
         *
         * @return {String} The filename and extension, e.g. "foobar.xls"
         */
        filenameFromUri: function(inUri) {
            // If the parameter is undefined/null...
            if (!inUri) {
                // ...just return an empty string
                return "";
            }

            var parts = inUri.split('/');

            return parts[parts.length - 1];
        },

        /**
         * Returns a formatted string version of the specified file size.
         *
         * @param {Number} inSize The file size in bytes.
         *
         * @return {String} A formatted size string (e.g. "204 KB" or "11 MB").
         */
        getFormattedFileSize: function(inSize) {
            var formattedSize, template;

            if (inSize !== undefined && inSize !== null) {
                // Pick a format based on the file size
                if (inSize < File.kKB_THRESHOLD) {
                    // Format: Bytes
                    template = File.kTEMPLATE_BYTES;
                    formattedSize = File.kFORMAT_BYTES.format(inSize);
                } else if (inSize / File.kONE_KILOBYTE < File.kMB_THRESHOLD) {
                    // Format: Kilobytes
                    template = File.kTEMPLATE_KILOBYTES;
                    formattedSize = File.kFORMAT_KILOBYTES.format(inSize / File.kONE_KILOBYTE);
                } else if (inSize / File.kONE_MEGABYTE < File.kGB_THRESHOLD) {
                    // Format: Megabytes
                    template = File.kTEMPLATE_MEGABYTES;
                    formattedSize = File.kFORMAT_MEGABYTES.format(inSize / File.kONE_MEGABYTE);
                } else {
                    // Format: Gigabytes
                    template = File.kTEMPLATE_GIGABYTES;
                    formattedSize = File.kFORMAT_GIGABYTES.format(inSize / File.kONE_GIGABYTE);
                }

		var rv = template.evaluate({ size: formattedSize });
                return rv;
            }

            return "";
        },

        /**
         * Returns the path of the icon file corresponding to the specified file type.
         *
         * @param {Number} inFileType One of the <tt>File.kFILETYPE_</tt>* constants.
         *
         * @return {String} A relative path to the icon corresponding to the specified file type,
         *                  e.g. "images/icon-folder.png".
         */
        getIconPath: function(inFileType) {
            switch (inFileType) {
            case File.kFILETYPE_DIR:
                return "images/icon-folder.png";
            case File.kFILETYPE_DOC:
                return "images/icon-doc.png";
            case File.kFILETYPE_PDF:
                return "images/icon-pdf.png";
            case File.kFILETYPE_PPT:
                return "images/icon-ppt.png";
            case File.kFILETYPE_TXT:
                return "images/icon-txt.png";
            case File.kFILETYPE_XLS:
                return "images/icon-xls.png";
            default:
                return "images/icon-generic.png";
            }
        },

        /**
         * Parses an ISO UTC formatted date (e.g. "2007-11-16T20:14:06Z").
         * The millisecond value (if any) is discarded.
         *
         * @param {String} inUtcDate The ISO UTC formatted date to be parsed.
         *
         * @return {Date} The parsed date.
         *
         * @protected
         */
        parseUtcDate: function(inUtcDate) {
            try {
                // Split the original string into two parts; date, and time
                var parts = inUtcDate.split('T');

                // The time component of the original ISO UTC formatted string may end with or
                // without milliseconds (".m[m[m]]") before the final 'Z'. Discard the final 'Z'
                // (and milliseconds if they are present) from the end of the time component
                if (parts[1].indexOf('.') > -1) {
                    parts[1] = parts[1].split('.')[0];
                } else {
                    parts[1] = parts[1].split('Z')[0];
                }

                // Split the date part into yyyy, mm, and dd
                var dateParts = parts[0].split('-');

                // Split the time part into hh, mm, and ss
                var timeParts = parts[1].split(':');

                // Put all the parts together into a date object
                return new Date(Date.UTC(
                    dateParts[0],       // Year
                    dateParts[1] - 1,   // Month (zero-based)
                    dateParts[2],       // Day
                    timeParts[0],       // Hour
                    timeParts[1],       // Minute
                    timeParts[2]));     // Second
            } catch (e) {
                console.error("File.parseUtcDate couldn't parse: " + inUtcDate);
                return undefined;
            }
        },

        /**
         * Removes the file protocol (file://) from a URI string.
         *
         * @param {String} inUri The URI/path, potentially starting with a file protocol.
         *
         * @return {String} A new string with the file protocol removed, or the original string if
         *                  none found.
         */
        stripFileProtocol: function(inUri) {
            if (inUri && inUri.toLowerCase().indexOf("file://") === 0) {
                return inUri.substring(7);
            }

            return inUri;
        },

        /**
         * Returns a flag indicating whether the specified timestamp occurs today.
         *
         * @param {Date} inTimestamp The date and time to be tested.
         *
         * @return {Boolean} <tt>true</tt> if the specified time occurs today, otherwise <tt>false</tt>.
         *
         * @protected
         */
        isToday: function(inTimestamp) {
            return (inTimestamp.getDate()  === File.today.getDate() &&
                    inTimestamp.getMonth() === File.today.getMonth() &&
                    inTimestamp.getYear()  === File.today.getYear() );
        },

        /**
         * Returns a flag indicating whether the specified timestamp occurs within the last 7 days.
         *
         * @param {Date} inTimestamp The date and time to be tested.
         *
         * @return {Boolean} <tt>true</tt> if the specified time occurs within the last 7 days, otherwise <tt>false</tt>.
         *
         * @protected
         */
        isLastSevenDays: function(inTimestamp) {
            // NOTE: This calculation doesn't take bi-yearly DST changes into account.
            //       That's OK for our application, but be aware if you copy and reuse...
            return (Math.abs((File.today.getTime() - inTimestamp.getTime()) / File.kONE_DAY_IN_MILLIS) <= 7);
        },

        /**
         * Returns a flag indicating whether the specified timestamp occurs this year.
         *
         * @param {Date} inTimestamp The date and time to be tested.
         *
         * @return {Boolean} <tt>true</tt> if the specified time occurs this year, otherwise <tt>false</tt>.
         *
         * @protected
         */
        isThisYear: function(inTimestamp) {
            return (inTimestamp.getYear() === File.today.getYear());
        },

        /**
         * Returns the file type constant corresponding to the specified extension.
         *
         * @param {String} inMimeType A mime type string, e.g. "application/vnd.ms-word"
         *
         * @return {Number} One of the <tt>File.kFILETYPE_</tt>* constants.
         *
         * @protected
         */
        typeFromMimeType: function(inMimeType) {
            switch (inMimeType ? inMimeType.toLowerCase() : "") {
                case "application/directory":
                    return File.kFILETYPE_DIR;

                case "application/doc":
                case "application/docx":
                case "application/ms-word":
                case "application/msword":
                case "application/vnd.ms-word":
                case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
                    return File.kFILETYPE_DOC;

                case "application/pdf":
                    return File.kFILETYPE_PDF;

                case "application/mspowerpoint":
                case "application/ppt":
                case "application/pptx":
                case "application/pps":
                case "application/ppsx":
                case "application/powerpoint":
                case "application/vnd.ms-powerpoint":
                case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
                case "application/x-mspowerpoint":
		 //if (QOWT.utils.editEnabled()) {
                    return File.kFILETYPE_PPT;

                case "text/plain":
                case "txt":
                    return File.kFILETYPE_TXT;

                case "application/excel":
                case "application/vnd.ms-excel":
                case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
                case "application/xls":
                case "application/xlsx":
                case "application/x-excel":
                case "application/x-msexcel":
                    return File.kFILETYPE_XLS;

                default:
                    return File.kFILETYPE_UNK;
            }
        },

        /**
         * Returns the file type constant corresponding to the specified extension.
         *
         * @param {String} inExtension A file extension without the leading period, e.g. "doc".
         *
         * @return {Number} One of the <tt>File.kFILETYPE_</tt>* constants.
         *
         * @protected
         */
        typeFromExtension: function(inExtension) {
            switch (inExtension ? inExtension.toLowerCase() : "") {
                case "doc":
                case "docx":
                    return File.kFILETYPE_DOC;

                case "pdf":
                    return File.kFILETYPE_PDF;

                case "ppt":
                case "pptx":
                case "pps":
                case "ppsx":
                    return File.kFILETYPE_PPT;

                case "txt":
                    return File.kFILETYPE_TXT;

                case "xls":
                case "xlsx":
                    return File.kFILETYPE_XLS;

                default:
                    return File.kFILETYPE_UNK;
            }
        }
    },

    /**
     * Called when the object is first made.
     */
    create: function() {
        this.inherited(arguments);

        this.uri        = this.uri || "";

        this.fileStem   = this.fileStem || "";
        this.extension  = this.extension || "";

        // Special handling for folders
        if (this.type === File.kFILETYPE_DIR) {
            // If the folder name was parsed as having an extension (because it includes
            // a period in the name)...
            if (this.extension.length > 0) {
                // ...reconstruct the filename
                this.fileStem += "." + this.extension;
                // ...and clear the extension
                this.extension = "";
            }
        }

        // If the file type hasn't been determined yet...
        if (this.type === undefined || this.type === File.kFILETYPE_UNK) {
            this.type = File.typeFromExtension(this.extension);
        }
    },

    /**
     * Returns the display extension, e.g. "doc".
     *
     * @return {String} The extension and extension.
     */
    getExtensionDisplay: function() {
        return (this.extensionDisplay ? this.extensionDisplay : this.extension);
    },

    /**
     * Returns the file name, e.g. "My <new & improved> design.doc".
     *
     * @return {String} The filename and extension.
     */
    getFilename: function() {
        // If we don't have a full filename...
        if (!this.filename) {
            // ...create one from file stem...
            this.filename = this.fileStem;

            // ...and extension
            if (this.extension && this.extension.length > 0) {
                this.filename += "." + this.extension;
            }
        }

        return this.filename;
    },

    /**
     * Returns the display filename, e.g. "doc".
     *
     * @return {String} The filename and filename.
     */
    getFilenameDisplay: function() {
        // If we don't have a full display filename, but we have the information to make one...
        if (!this.filenameDisplay && this.fileStemDisplay) {
            // ...create one from file stem...
            this.filenameDisplay = this.fileStemDisplay;

            // ...and extension
            if (this.extensionDisplay && this.extensionDisplay.length > 0) {
                this.filenameDisplay += "." + this.extensionDisplay;
            }

            return this.filenameDisplay;
        }

        // ...otherwise, just return the filename
        return this.getFilename();
    },

    /**
     * Returns the display filename with the extension on the end (e.g. "Foo.docx").
     *
     * @return {String} The display file name with extension.
     */
    getFilenameDisplayWithExtension: function() {
        // By default, if there is a fileNameDisplay, just use it.
        var returnValue = this.fileNameDisplay;
        if (!returnValue) {
            // If there's no fileNameDisplay, need to return something else...
            // If there's no file stem or extension, just use the file name.
            if (!this.fileStemDisplay || !this.extensionDisplay) {
                returnValue = this.getFilename();
            }
            else {
                // Otherwise, create one from file stem...
                returnValue = this.fileStemDisplay;

                // ...and extension
                returnValue += "." + this.extensionDisplay;
            }
        }

        return returnValue;
    },

    /**
     * Returns the display fileStem, e.g. "doc".
     *
     * @return {String} The fileStem and fileStem.
     */
    getFileStemDisplay: function() {
        return (this.fileStemDisplay ? this.fileStemDisplay : this.fileStem);
    },

    /**
     * Returns the name of a kind for handling this file type.
     *
     * @return {String} The name of a kind for handling this file type (e.g. "PdfView").
     */
    getHandlerKind: function() {
        return File.handlers[this.getType()];
    },

    /**
     * Returns the path of the icon file for this object.
     *
     * @return {String} A relative path to the icon file that represents this file system object's
     *                  type, e.g. "images/icon-folder.png".
     */
    getIconPath: function() {
        // If we haven't previously cached this result...
        if (!this.iconPath) {
            // ...do the lookup and cache the result
            this.iconPath = File.getIconPath(this.getType());
        }

        return this.iconPath;
    },

    /**
     * Returns this file system object's size as a formatted and localized display string.
     *
     * @return {String} A file size display string (e.g. "999 KB", "0.98 MB", etc.)
     */
    getSizeFormatted: function() {
        if (!this.formattedFileSize) {
            this.formattedFileSize = File.getFormattedFileSize(this.size);
        }

        return this.formattedFileSize;
    },

    /**
     * Returns this file system object's timestamp as a formatted and localized display string.
     *
     * @return {String} A file modification time/date display string (e.g. "March 16 11:06 PM", etc.)
     */
    getTimestampFormatted: function() {
        // If we haven't previously cached this result...
        if (!this.formattedFileDate) {
            // ...do the formatting and cache the result

            // First, check for an invalid or missing date
            if (!this.timestamp || isNaN(this.timestamp.getTime())) {
                this.formattedFileDate = "";
            } else {
                // One consistent full date+time for every file (instead of the stock recency
                // variants that mixed styles in the same list), but LOCALIZED via enyo.g11n so it
                // follows the system date format - month names in the UI language, locale date-
                // component order (e.g. "May 17, 2026" vs "17 May 2026"), and the 12/24h time pref.
                this.formattedFileDate = File.kFORMAT_ALWAYS.format(this.timestamp);
            }
        }

        return this.formattedFileDate;
    },

    /**
     * Returns a flag indicating whether this file system object represents a file.
     *
     * @return {Boolean} <tt>true</tt> if this object represents a file, otherwise <tt>false</tt>.
     */
    isFile: function() {
        return (this.getType() !== File.kFILETYPE_DIR);
    },

    /**
     * Returns a flag indicating whether this file system object represents a file.
     *
     * @return {Boolean} <tt>true</tt> if this object represents a file, otherwise <tt>false</tt>.
     */
    isFolder: function() {
        return (this.getType() === File.kFILETYPE_DIR);
    },

    /**
     * Returns a flag indicating whether this file system object represents a root folder.
     *
     * @return {Boolean} <tt>true</tt> if this object represents a root folder, otherwise <tt>false</tt>.
     */
    isRoot: function() {
        return (this.getType() === File.kFILETYPE_DIR && !this.uri);
    },

    /**
     * Returns a flag indicating whether this file system object represents a root folder.
     *
     * @return {Boolean} <tt>true</tt> if this object represents a root folder, otherwise <tt>false</tt>.
     */
    isHandled: function() {
        if(this.isFolder()) {
	        return true;
        } else {
	        if(this.getType() == File.kFILETYPE_PPT && enyo.fetchAppInfo().legacyPpt===undefined) {
		        return false;
	        } else {
		        return (File.handlers[this.getType()] !== undefined);
	        }
        }
    }
});
