require 'xcodeproj'
require 'pathname'
ios = File.expand_path(ARGV.fetch(0))
project = Xcodeproj::Project.open(File.join(ios, 'Runner.xcodeproj'))
target = project.targets.find { |item| item.name == 'Runner' } or abort('Runner target missing')
runner = project.main_group.find_subpath('Runner', false) or abort('Runner group missing')
variants = runner.children.find { |ref| ref.isa == 'PBXVariantGroup' && ref.name == 'InfoPlist.strings' }
variants ||= runner.new_variant_group('InfoPlist.strings')
Dir.glob(File.join(ios, 'Runner', '*.lproj', 'InfoPlist.strings')).each do |file|
  language = File.basename(File.dirname(file), '.lproj')
  reference = variants.children.find { |ref| ref.name == language }
  reference ||= variants.new_file("#{language}.lproj/InfoPlist.strings")
  reference.name = language
  project.root_object.known_regions |= [language]
end
unless target.resources_build_phase.files_references.include?(variants)
  target.resources_build_phase.add_file_reference(variants)
end
project.save
