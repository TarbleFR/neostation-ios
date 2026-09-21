#!/usr/bin/env ruby
# Add the classic NeoStation icon fallbacks to Runner's Copy Bundle Resources.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'ios', 'Runner.xcodeproj')
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |candidate| candidate.name == 'Runner' }
abort('Runner target not found') unless target

group = project.main_group.find_subpath('Runner/IconFallback', true)
fallbacks = %w[
  NeoStationIcon60@2x.png
  NeoStationIcon60@3x.png
  NeoStationIcon76@2x~ipad.png
  NeoStationIcon83.5@2x~ipad.png
  NeoStationIcon1024.png
]

fallbacks.each do |name|
  ref = group.files.find { |candidate| candidate.path == name } || group.new_file(name)
  unless target.resources_build_phase.files_references.include?(ref)
    target.resources_build_phase.add_file_reference(ref, true)
  end
end

project.save
puts "Added #{fallbacks.length} SpringBoard fallback icons to Runner resources."
