#!/usr/bin/env ruby
# Generates MacMixer.xcodeproj from the sources in MacMixer/.
# Run once (build.sh does this automatically): `ruby project.rb`.

require 'xcodeproj'

root = File.dirname(File.expand_path(__FILE__))
proj_path = File.join(root, 'MacMixer.xcodeproj')

# Start clean so regeneration is deterministic.
require 'fileutils'
FileUtils.rm_rf(proj_path)

project = Xcodeproj::Project.new(proj_path)
target = project.new_target(:application, 'MacMixer', :osx, '14.2')

group = project.main_group.new_group('MacMixer', 'MacMixer')
Dir.glob(File.join(root, 'MacMixer', '*.swift')).sort.each do |f|
  file_ref = group.new_file(File.basename(f))
  target.source_build_phase.add_file_reference(file_ref)
end

# App icon (.icns) -> bundle Resources; Info.plist points CFBundleIconFile here.
icns = group.new_file('MacMixer.icns')
target.resources_build_phase.add_file_reference(icns)

# System frameworks (AppKit/SwiftUI auto-link via import, but be explicit).
target.add_system_framework(%w[CoreAudio AudioToolbox AppKit SwiftUI])

target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_NAME'] = 'MacMixer'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.macmixer.app'
  s['INFOPLIST_FILE'] = 'MacMixer/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['SWIFT_VERSION'] = '5.0'
  s['MACOSX_DEPLOYMENT_TARGET'] = '14.2'
  s['MARKETING_VERSION'] = '2.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['CODE_SIGN_STYLE'] = 'Manual'
  s['CODE_SIGN_IDENTITY'] = '-'        # ad-hoc / Sign to Run Locally
  s['DEVELOPMENT_TEAM'] = ''
  s['ENABLE_HARDENED_RUNTIME'] = 'NO'
  s['ENABLE_APP_SANDBOX'] = 'NO'
  s['COMBINE_HIDPI_IMAGES'] = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks']
  s['GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS'] = 'NO'
end

project.save
puts "Wrote #{proj_path}"
