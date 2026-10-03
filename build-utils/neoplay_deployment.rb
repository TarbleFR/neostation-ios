# Change only the generated Runner target, not emulator/JIT/helper targets.
require 'xcodeproj'
require 'rubygems/version'

ios = File.expand_path(ARGV.fetch(0))
minimum = Gem::Version.new(ARGV.fetch(1))
project = Xcodeproj::Project.open(File.join(ios, 'Runner.xcodeproj'))
runner = project.targets.find { |target| target.name == 'Runner' } or abort('Runner target missing')
abort('Runner build configurations missing') if runner.build_configurations.empty?
runner.build_configurations.each do |configuration|
  current = configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
  inherited = project.build_configurations.find { |item| item.name == configuration.name }
  effective = current || inherited&.build_settings&.fetch('IPHONEOS_DEPLOYMENT_TARGET', nil)
  if current.nil? || Gem::Version.new(current) < minimum
    configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] =
      effective && Gem::Version.new(effective) > minimum ? effective : minimum.to_s
  end
end
project.save
