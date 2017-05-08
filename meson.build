project('rygel', ['vala', 'c'],
        version : '0.35.0')

rygel_sysconfdir = join_paths(get_option('prefix'), get_option('sysconfdir'))
rygel_datadir = join_paths(get_option('prefix'), get_option('datadir'))
rygel_plugindir = join_paths(get_option('prefix'), get_option('libdir'), 'rygel-2.6', 'plugins')
rygel_bigicondir = join_paths(rygel_datadir, 'rygel', 'icons', '120x120')
rygel_smallicondir = join_paths(rygel_datadir, 'rygel', 'icons', '48x48')

conf = configuration_data()
conf.set('GETTEXT_PACKAGE', '"rygel"')
conf.set('PACKAGE_NAME', '"Rygel"')
conf.set('PACKAGE_STRING', '"Rygel @0@"'.format(meson.project_version()))
conf.set('DATA_DIR', '"@0@"'.format(rygel_datadir))
conf.set('PLUGIN_DIR', '"@0@"'.format(rygel_plugindir))
conf.set('BIG_ICON_DIR', '"@0@"'.format(rygel_bigicondir))
conf.set('SMALL_ICON_DIR', '"@0@"'.format(rygel_smallicondir))
conf.set('SYS_CONFIG_DIR', '"@0@"'.format(rygel_sysconfdir))
configure_file(output: 'config.h', configuration: conf)

add_global_arguments(['-include','config.h'], language : 'c')

vala = meson.get_compiler('vala')
gupnp = dependency('gupnp-1.0', version : '>= 0.24.14')
gee = dependency('gee-0.8', version: '>= 0.8.0')
gssdp = dependency('gssdp-1.0', version : '>= 0.13.0')
gio = dependency('gio-2.0', version : '>= 2.26')
gmodule = dependency('gmodule-2.0')
libxml = dependency('libxml-2.0', version: '>= 2.7')
posix = vala.find_library('posix')

cc = meson.get_compiler('c')
math = cc.find_library('m', required: false)

common_deps = [gupnp, gee]

core_deps = common_deps + [gssdp, gio, gmodule, libxml, posix, math]

subdir('src')
