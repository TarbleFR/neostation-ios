# Real xcodeproj fixture, independent of Flutter/emulator binaries. This checks
# the production Runner metadata editor against actual serialized PBX objects.
require 'xcodeproj'
require 'json'
require 'fileutils'

command, directory, report_path = ARGV
directory = File.expand_path(directory)
project_path = File.join(directory, 'Runner.xcodeproj')
identity_path = File.join(directory, 'fixture-before.json')

def deep_copy(value)
  JSON.parse(JSON.generate(value))
end

def target_snapshot(target)
  deep_copy({
    'target' => target.to_hash,
    'configurations' => target.build_configurations.map(&:to_hash),
    'phases' => target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
    'dependencies' => target.dependencies.map(&:to_hash)
  })
end

if command == 'create'
  FileUtils.mkdir_p(File.join(directory, 'Runner'))
  project = Xcodeproj::Project.new(project_path)
  runner = project.new_target(:application, 'Runner', :ios, '17.4')
  other = project.new_target(:framework, 'OtherEmulator', :ios, '16.0')
  runner.add_build_configuration('Profile', :release)
  group = project.main_group.new_group('Runner', 'Runner')
  File.write(File.join(directory, 'Runner', 'Main.m'), '/* Metadata fixture only: never shipped. */')
  File.write(File.join(directory, 'Runner', 'Other.m'), '/* Protected existing native target fixture. */')
  runner.source_build_phase.add_file_reference(group.new_file('Main.m'))
  other.source_build_phase.add_file_reference(group.new_file('Other.m'))
  runner.add_dependency(other)
  copy = runner.new_copy_files_build_phase('Existing native runtime copy')
  copy.dst_subfolder_spec = '10'
  runtime = project.main_group.new_file('ExistingRuntime.framework')
  build = copy.add_file_reference(runtime, true)
  build.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  runner.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.neogamelab.neostation'
    settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
    settings['NEOSTATION_UNRELATED_SETTING'] = 'must remain unchanged'
    case configuration.name
    when 'Debug'
      settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
      settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) "@loader_path/Other Runtime.framework"'
    when 'Release'
      settings['IPHONEOS_DEPLOYMENT_TARGET'] = '19.0'
      settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Other Frameworks']
    when 'Profile'
      settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
      settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks'
    end
  end
  other.build_configurations.each do |configuration|
    configuration.build_settings['NEOSTATION_NATIVE_IDENTITY'] = 'protected other emulator'
    configuration.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['@loader_path/Frameworks']
  end
  project.save
  # Take snapshots after serialization/reopen, so the comparison concerns
  # production edits rather than xcodeproj's initial normalization.
  project = Xcodeproj::Project.open(project_path)
  runner = project.targets.find { |target| target.name == 'Runner' }
  identity = {
    'targets' => project.targets.map(&:name).sort,
    'protectedTargets' => project.targets.reject { |target| target == runner }.to_h { |target| [target.uuid, target_snapshot(target)] },
    'runnerTarget' => deep_copy(runner.to_hash),
    'runnerPhases' => deep_copy(runner.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] }),
    'runnerDependencies' => deep_copy(runner.dependencies.map(&:to_hash)),
    'runnerConfigurations' => runner.build_configurations.to_h { |configuration| [configuration.name, deep_copy(configuration.build_settings)] },
    'projectConfigurations' => deep_copy(project.build_configurations.map(&:to_hash))
  }
  File.write(identity_path, JSON.pretty_generate(identity) + "\n")
  puts "Created actual #{Xcodeproj::VERSION} Runner/OtherEmulator project fixture."
elsif command == 'verify'
  project = Xcodeproj::Project.open(project_path)
  identity = JSON.parse(File.read(identity_path))
  runner = project.targets.find { |target| target.name == 'Runner' }
  raise 'Runner disappeared' unless runner
  raise 'Existing target set changed' unless project.targets.map(&:name).sort == identity['targets']
  protected = project.targets.reject { |target| target == runner }.to_h { |target| [target.uuid, target_snapshot(target)] }
  raise 'Another emulator target changed' unless protected == identity['protectedTargets']
  raise 'Runner identity changed' unless deep_copy(runner.to_hash) == identity['runnerTarget']
  raise 'Runner native build phases changed' unless deep_copy(runner.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] }) == identity['runnerPhases']
  raise 'Runner native dependency graph changed' unless deep_copy(runner.dependencies.map(&:to_hash)) == identity['runnerDependencies']
  raise 'Global project configuration changed' unless deep_copy(project.build_configurations.map(&:to_hash)) == identity['projectConfigurations']
  runner.build_configurations.each do |configuration|
    expected = deep_copy(identity['runnerConfigurations'].fetch(configuration.name))
    current = expected['IPHONEOS_DEPLOYMENT_TARGET']
    expected['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0' if Gem::Version.new(current) < Gem::Version.new('18.0')
    if configuration.name == 'Debug'
      expected['LD_RUNPATH_SEARCH_PATHS'] += ' @executable_path/Frameworks'
    end
    raise "Unexpected Runner settings edit: #{configuration.name}" unless deep_copy(configuration.build_settings) == expected
  end
  report = {
    'success' => true, 'xcodeprojVersion' => Xcodeproj::VERSION,
    'checkedTargets' => identity['targets'], 'runnerDeploymentFloor' => '18.0',
    'newerDeploymentPreserved' => true, 'quotedRunpathsPreserved' => true,
    'arrayRunpathsPreserved' => true, 'otherNativeTargetsUnchanged' => true,
    'existingRunnerPhasesUnchanged' => true, 'nativeDependenciesUnchanged' => true,
    'deviceValidated' => false
  }
  File.write(report_path, JSON.pretty_generate(report) + "\n")
  puts JSON.pretty_generate(report)
else
  raise 'Usage: host_configuration_fixture.rb create|verify IOS_DIRECTORY [REPORT_PATH]'
end
