/*
 * Copyright (C) 2009 Jens Georg <mail@jensge.org>.
 *
 * This file is part of Rygel.
 *
 * Rygel is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * Rygel is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 */

using Gee;
using GUPnP;

/**
 * Represents the root container.
 */
public class Rygel.MediaExportRootContainer : Rygel.MediaDBContainer {
    private MetadataExtractor extractor;
    private HashMap<File, MediaExportHarvester> harvester;
    private MediaExportRecursiveFileMonitor monitor;
    private MediaExportDBusService service;
    private MediaExportDynamicContainer dynamic_elements;
    private Gee.List<MediaExportHarvester> harvester_trash;

    private static MediaContainer instance = null;

    private ArrayList<string> get_uris () {
        ArrayList<string> uris;

        var config = MetaConfig.get_default ();

        try {
            uris = config.get_string_list ("MediaExport", "uris");
        } catch (Error error) {
            uris = new ArrayList<string> ();
        }

        // either an error occured or the gconf key is not set
        if (uris.size == 0) {
            debug("Nothing configured, using XDG special directories");
            var uri = Environment.get_user_special_dir (UserDirectory.MUSIC);
            if (uri != null)
                uris.add (uri);

            uri = Environment.get_user_special_dir (UserDirectory.PICTURES);
            if (uri != null)
                uris.add (uri);

            uri = Environment.get_user_special_dir (UserDirectory.VIDEOS);
            if (uri != null)
                uris.add (uri);
        }

        var dbus_uris = this.dynamic_elements.get_uris ();
        if (dbus_uris != null) {
            uris.add_all (dbus_uris);
        }

        return uris;
    }

    public static MediaContainer get_instance() {
        if (MediaExportRootContainer.instance == null) {
            try {
                MediaExportRootContainer.instance =
                                             new MediaExportRootContainer ();
            } catch (Error err) {
                warning("Failed to create instance of database");
                MediaExportRootContainer.instance = new NullContainer ();
            }
        }

        return MediaExportRootContainer.instance;
    }

    public void add_uri (string uri) {
        var file = File.new_for_commandline_arg (uri);
        this.harvest (file, this.dynamic_elements);
    }

    public void remove_uri (string uri) {
        var file = File.new_for_commandline_arg (uri);
        var id = Checksum.compute_for_string (ChecksumType.MD5,
                                              file.get_uri ());

        try {
            this.media_db.remove_by_id (id);
        } catch (Error e) {
            warning ("Failed to remove uri: %s", e.message);
        }
    }

    MediaExportQueryContainer? search_to_virtual_container (
                                       RelationalExpression exp) {
        if (exp.operand1 == "upnp:class" &&
            exp.op == SearchCriteriaOp.EQ) {
            switch (exp.operand2) {
                case "object.container.album.musicAlbum":
                    string id = "virtual-container:upnp:album,?";
                    MediaExportQueryContainer.register_id (ref id);

                    return new MediaExportQueryContainer (this.media_db,
                                                          id,
                                                          "Albums");

                case "object.container.person.musicArtist":
                    string id = "virtual-container:dc:creator,?,upnp:album,?";
                    MediaExportQueryContainer.register_id (ref id);

                    return new MediaExportQueryContainer (this.media_db,
                                                          id,
                                                          "Artists");
                default:
                    return null;
            }
        }

        return null;
    }

    public override async Gee.List<MediaObject>? search (
                                        SearchExpression expression,
                                        uint             offset,
                                        uint             max_count,
                                        out uint         total_matches,
                                        Cancellable?     cancellable)
                                        throws GLib.Error {
        Gee.List<MediaObject> list;
        MediaExportQueryContainer query_container;

        if (expression is RelationalExpression) {
            var exp = expression as RelationalExpression;

            query_container = search_to_virtual_container (exp);
            if (query_container != null) {
                query_container.parent = this;
                list = yield query_container.get_children (offset,
                                                           max_count,
                                                           cancellable);
                foreach (var o1 in list) {
                    o1.upnp_class = exp.operand2;
                }
                total_matches = list.size;
                return list;
            }

            if (exp.operand1 == "@id" &&
                exp.op == SearchCriteriaOp.EQ &&
                exp.operand2.has_prefix (MediaExportQueryContainer.PREFIX)) {
                var real_id = MediaExportQueryContainer.get_virtual_container_definition
                (exp.operand2);
                list = new ArrayList<MediaObject> ();
                if (real_id != null) {
                    var args = real_id.split (",");
                    query_container = new MediaExportQueryContainer (
                                        this.media_db,
                                        exp.operand2,
                                        args[args.length - 1]);
                    query_container.parent = this;
                    list.add (query_container);
                }
                total_matches = list.size;
                return list;
            }
        }

        if (expression is LogicalExpression) {
            var logical_expression = expression as LogicalExpression;
            if (logical_expression.operand1 is RelationalExpression &&
                logical_expression.operand2 is RelationalExpression &&
                logical_expression.op == LogicalOperator.AND) {
                var expa = logical_expression.operand1 as RelationalExpression;
                var expb = logical_expression.operand2 as RelationalExpression;
                query_container = search_to_virtual_container (expa);
                RelationalExpression exp_ = null;
                if (query_container == null) {
                    query_container = search_to_virtual_container (expb);
                    if (query_container != null) {
                        exp_ = expa;
                    }
                } else {
                    exp_ = expb;
                }

                if (query_container != null) {
                    var last_argument = query_container.plaintext_id.replace (
                                        MediaExportQueryContainer.PREFIX,
                                        "");
                    var new_id = MediaExportQueryContainer.PREFIX;
                    new_id += exp_.operand1 + "," +
                              Uri.escape_string (exp_.operand2, "", true) +
                              last_argument;
                    debug ("Translated search request to %s", new_id);
                    MediaExportQueryContainer.register_id (ref new_id);
                    query_container = new MediaExportQueryContainer (
                                        this.media_db,
                                        new_id,
                                        exp_.operand2);

                    list = yield query_container.get_children (offset,
                                                               max_count,
                                                               cancellable);
                    foreach (var o2 in list) {
                        o2.upnp_class = expa.operand2;
                    }
                    total_matches = list.size;
                    return list;
                }

            }
        }

        return yield base.search (expression,
                                  offset,
                                  max_count,
                                  out total_matches,
                                  cancellable);
    }


    public string[] get_dynamic_uris () {
        var dynamic_uris = this.dynamic_elements.get_uris ();

        return dynamic_uris.to_array ();
    }


    /**
     * Create a new root container.
     */
    private MediaExportRootContainer () throws Error {
        var object_factory = new MediaExportObjectFactory ();
        var db = new MediaDB.with_factory ("media-export", object_factory);

        base (db, "0", "MediaExportRoot");

        this.extractor = MetadataExtractor.create ();

        this.harvester = new HashMap<File,MediaExportHarvester> (file_hash,
                                                                 file_equal);
        this.harvester_trash = new ArrayList<MediaExportHarvester> ();

        this.monitor = new MediaExportRecursiveFileMonitor (null);
        this.monitor.changed.connect (this.on_file_changed);

        try {
            this.service = new MediaExportDBusService (this);
        } catch (Error err) {
            warning ("Failed to create MediaExport DBus service: %s",
                     err.message);
        }
        this.dynamic_elements = new MediaExportDynamicContainer (db, this);

        try {
            int64 timestamp;
            if (!this.media_db.exists ("0", out timestamp)) {
                media_db.save_container (this);
            }

            if (!this.media_db.exists ("DynamicContainerId", out timestamp)) {
                media_db.save_container (this.dynamic_elements);
            }
        } catch (Error error) {
            // do nothing
        }

        ArrayList<string> ids;
        try {
            ids = media_db.get_child_ids ("0");
        } catch (DatabaseError e) {
            ids = new ArrayList<string>();
        }

        var uris = get_uris ();
        foreach (var uri in uris) {
            var file = File.new_for_commandline_arg (uri);
            if (file.query_exists (null)) {
                var id = Checksum.compute_for_string (ChecksumType.MD5,
                                                      file.get_uri ());
                ids.remove (id);
                this.harvest (file);
            }
        }

        try {
            var config = MetaConfig.get_default ();
            var virtual_containers = config.get_string_list (
                                        "MediaExport",
                                        "virtual-folders");
            foreach (var container in virtual_containers) {
                var info = container.split ("=");
                var id = MediaExportQueryContainer.PREFIX + info[1];
                if (!MediaExportQueryContainer.validate_virtual_id (id)) {
                    warning ("%s is not a valid virtual id", id);

                    continue;
                }
                MediaExportQueryContainer.register_id (ref id);

                var virtual_container = new MediaExportQueryContainer (
                                        this.media_db,
                                        id,
                                        info[0]);
                virtual_container.parent = this;
                try {
                    this.media_db.save_container (virtual_container);
                } catch (Error db_err) {
                    // do nothing
                }
                ids.remove (id);
            }
        } catch (Error error) {
            warning ("Got error while trying to find virtual folders: %s",
                     error.message);
        }

        foreach (var id in ids) {
            if (id == MediaExportDynamicContainer.ID)
                continue;

            debug ("Id %s no longer in config, deleting...",
                   id);
            try {
                this.media_db.remove_by_id (id);
            } catch (DatabaseError e) {
                warning ("Failed to remove entry: %s", e.message);
            }
        }

        this.updated ();
    }

    private void on_file_harvested (MediaExportHarvester harvester,
                                    File                 file) {
        message ("'%s' harvested", file.get_uri ());

        this.harvester.remove (file);
    }

    private void on_remove_cancelled_harvester (MediaExportHarvester harvester,
                                                File                 file) {
        this.harvester_trash.remove (harvester);
    }

    private void harvest (File file, MediaContainer parent = this) {
        if (this.extractor == null) {
            warning ("No Metadata extractor available. Will not crawl");
            return;
        }

        if (this.harvester.contains (file)) {
            debug ("Already harvesting; cancelling");
            var harvester = this.harvester[file];
            harvester.harvested.disconnect (this.on_file_harvested);
            harvester.cancellable.cancel ();
            harvester.harvested.connect (this.on_remove_cancelled_harvester);
            this.harvester_trash.add (harvester);
        }

        var harvester = new MediaExportHarvester (parent,
                                                  this.media_db,
                                                  this.extractor,
                                                  this.monitor);
        harvester.harvested.connect (this.on_file_harvested);
        this.harvester[file] = harvester;
        harvester.harvest (file);
    }

    private void on_file_changed (File             file,
                                  File?            other,
                                  FileMonitorEvent event) {
        switch (event) {
            case FileMonitorEvent.CREATED:
            case FileMonitorEvent.CHANGES_DONE_HINT:
                debug ("Trying to harvest %s because of %d", file.get_uri (),
                        event);
                var parent = file.get_parent ();
                var id = Checksum.compute_for_string (ChecksumType.MD5,
                                                      parent.get_uri ());
                try {
                    var parent_container = this.media_db.get_object (id);
                    if (parent_container != null) {
                        this.harvest (file, (MediaContainer)parent_container);
                    } else {
                        assert_not_reached ();
                    }
                } catch (Rygel.DatabaseError error) {
                    warning ("Error while getting parent container for " +
                             "filesystem event: %s",
                             error.message);
                }
                break;
            case FileMonitorEvent.DELETED:
                var id = Checksum.compute_for_string (ChecksumType.MD5,
                                                      file.get_uri ());

                try {
                    // the full object is fetched instead of simply calling exists
                    // because we need the parent to signalize the change
                    var obj = this.media_db.get_object (id);

                    // it may be that files removed are files that are not
                    // in the database, because they're not media files
                    if (obj != null) {
                        this.media_db.remove_object (obj);
                        if (obj.parent != null) {
                            obj.parent.updated ();
                        }
                    }
                } catch (Error error) {
                    warning ("Error removing object from database: %s",
                             error.message);
                }
                break;
            default:
                break;
        }
    }
}
