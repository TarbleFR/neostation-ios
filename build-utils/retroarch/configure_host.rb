# Runner-only, idempotent metadata changes; existing native emulator phases and
# other targets must remain byte-for-byte equivalent in their project model.
require 'xcodeproj'
require 'shellwords'

project = Xcodeproj::Project.open(ARGV.fetch(0))
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Generated Runner target is missing' unless runner

def snapshot(target)
  {
    'target' => target.to_hash,
    'configurations' => target.build_configurations.map(&:to_hash),
    'phases' => target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
    'dependencies' => target.dependencies.map(&:to_hash)
  }
end
protected = project.targets.reject { |target| target == runner }
before = protected.to_h { |target| [target.uuid, snapshot(target)] }
phases_before = runner.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] }
runner.build_configurations.each do |configuration|
  settings = configuration.build_settings
  current = settings['IPHONEOS_DEPLOYMENT_TARGET']
  if current && !current.match?(/\A\d+(?:\.\d+)*\z/)
    raise "Cannot resolve Runner deployment target #{current.inspect}"
  end
  if !current || Gem::Version.new(current) < Gem::Version.new('18.0')
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  end
  runpaths = settings['LD_RUNPATH_SEARCH_PATHS']
  values = runpaths.is_a?(Array) ? runpaths.dup : Shellwords.split(runpaths || '$(inherited)')
  unless values.include?('@executable_path/Frameworks')
    settings['LD_RUNPATH_SEARCH_PATHS'] = if runpaths.is_a?(Array)
      values + ['@executable_path/Frameworks']
    else
      # Keep existing quoting/search paths intact; only append our required path.
      [runpaths || '$(inherited)', '@executable_path/Frameworks'].join(' ')
    end
  end
end
raise 'An existing native emulator target changed' unless protected.to_h { |target| [target.uuid, snapshot(target)] } == before
raise 'An existing Runner native build phase changed' unless runner.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] } == phases_before
project.save
puts 'Runner iOS 18 minimum and lazy-loaded Frameworks runpath configured; native phases unchanged.'
