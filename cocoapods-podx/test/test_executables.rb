require 'fileutils'
require 'open3'
require 'rbconfig'
require 'rubygems'
require 'shellwords'
require 'tmpdir'
require 'minitest/autorun'

class CocoapodsPodxExecutablesTest < Minitest::Test
  REPO_DIR = File.expand_path('../..', __dir__)
  RUBY_BIN = RbConfig.ruby
  GEM_BIN = File.join(RbConfig::CONFIG.fetch('bindir'), 'gem')

  def setup
    @dir = Dir.mktmpdir('podx executables ')
    @source = File.join(@dir, 'source with spaces', 'cocoapods-podx')
    @gem_home = File.join(@dir, 'gem home')
    @bin_dir = File.join(@gem_home, 'bin')
    @fixture_bin = File.join(@dir, 'fixtures')
    FileUtils.mkdir_p([@source, @bin_dir, @fixture_bin, File.join(@gem_home, 'specifications')])
    %w[bin lib cocoapods-podx.gemspec].each do |name|
      FileUtils.cp_r(File.join(REPO_DIR, 'cocoapods-podx', name), @source)
    end
    @version = Gem::Specification.load(File.join(@source, 'cocoapods-podx.gemspec')).version.to_s
    @env = {
      'GEM_HOME' => @gem_home,
      'GEM_PATH' => @gem_home,
      'GEM_SPEC_CACHE' => File.join(@dir, 'spec-cache'),
      'PATH' => [@fixture_bin, @bin_dir, File.dirname(RUBY_BIN), '/usr/bin', '/bin'].join(File::PATH_SEPARATOR),
      'RUBYOPT' => nil,
      'RUBYLIB' => nil,
      'COCOAPODS_PODX_LOCAL_LIB' => nil,
      'COCOAPODS_PODX_COMMAND_DIR' => nil,
      'COCOAPODS_PODX_GIT_TOKEN' => 'unused-test-token'
    }

    # Bootstrap commands need dependency activation, but do not execute CocoaPods.
    File.write(File.join(@gem_home, 'specifications', 'cocoapods-1.16.2.gemspec'), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = 'cocoapods'
        spec.version = '1.16.2'
      end
    RUBY
    write_executable(File.join(@fixture_bin, 'pod'), "#!#{RUBY_BIN}\n")
    write_executable(File.join(@fixture_bin, 'curl'), <<~SH)
      #!/bin/sh
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -o) cp "$PODX_TEST_GEM_FILE" "$2"; exit $? ;;
          --upload-file) exit 0 ;;
        esac
        shift
      done
      exit 1
    SH
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_gem_install_and_reinstall_produce_working_commands
    package = build_gem
    2.times do
      install_gem(package)
      assert_commands_work(@version)
    end
  end

  def test_gem_launchers_preserve_arguments_exit_status_and_command_directory
    install_gem(build_gem)
    arguments = ['argument with spaces', '--flag=value', '$(exit 99)', '']
    %w[podx mgit].each do |name|
      File.write(File.join(installed_dir, 'lib', 'cocoapods_podx', 'shims', name), <<~SH)
        #!/bin/sh
        printf '%s\n' "$COCOAPODS_PODX_COMMAND_DIR"
        printf '<%s>\n' "$@"
        exit 37
      SH
      stdout, stderr, status = capture(File.join(@bin_dir, name), *arguments)
      assert_equal 37, status.exitstatus, stderr
      assert_equal [@bin_dir, *arguments.map { |arg| "<#{arg}>" }].join("\n") + "\n", stdout
    end
  end

  def test_publish_keeps_ruby_entrypoints_in_the_built_gem
    script = File.join(File.dirname(@source), 'publish-cocoapods-podx.sh')
    FileUtils.cp(File.join(REPO_DIR, 'publish-cocoapods-podx.sh'), script)
    run_success('/bin/sh', script, @version, env: {
      'COCOAPODS_PODX_RUBY_BIN' => RUBY_BIN,
      'COCOAPODS_PODX_GEM_BIN' => GEM_BIN,
      'COCOAPODS_PODX_GEM_SOURCE' => 'https://example.invalid/gems'
    })
    install_gem(File.join(@source, "cocoapods-podx-#{@version}.gem"))
    assert_commands_work(@version)
  end

  def test_launchers_copied_by_older_upgrade_scripts_find_the_installed_gem
    install_gem(build_gem)
    command_dir = File.join(@dir, 'legacy commands')
    FileUtils.mkdir_p(command_dir)
    %w[podx mgit].each do |name|
      destination = File.join(command_dir, name)
      FileUtils.cp(File.join(installed_dir, 'bin', name), destination)
      stdout = run_success(destination, '--help')
      assert_includes stdout, name == 'podx' ? 'podx install' : 'mgit branch'
    end
    assert_equal "cocoapods-podx #{@version}\n", run_success(File.join(command_dir, 'podx'), '--version')
  end

  def test_installer_copies_shell_templates_from_local_and_installed_sources
    install_gem(build_gem)
    script = File.read(File.join(REPO_DIR, 'install-cocoapods-podx.sh'))
    helpers = %w[install_generated_shim copy_command_shim].map do |name|
      script[/^#{name}\(\) \{\n.*?^\}\n/m] or raise "Missing #{name}"
    end.join("\n")
    [File.dirname(@source), File.join(@dir, 'downloaded-installer')].each_with_index do |source_dir, index|
      %w[podx mgit].each do |name|
        destination = File.join(@dir, "installed-#{index}-#{name}")
        run_success('/bin/sh', '-c', helpers + "\n" + 'copy_command_shim "$1" "$2"',
                    'installer-test', name, destination, env: {
                      'SCRIPT_DIR' => source_dir,
                      'COCOAPODS_GEM_HOME' => @gem_home,
                      'RUBY_BIN' => RUBY_BIN,
                      'PUBLISH_ONLY_MODE' => '1'
                    })
        stdout = run_success(destination, '--help')
        assert_includes stdout, name == 'podx' ? 'podx install' : 'mgit branch'
      end
    end
  end

  def test_legacy_copied_launchers_work_when_path_ruby_uses_a_different_gem_environment
    install_gem(build_gem)
    other_ruby = File.executable?('/usr/bin/ruby') ? '/usr/bin/ruby' : RUBY_BIN
    write_executable(File.join(@fixture_bin, 'ruby'), "#!/bin/sh\nexec #{other_ruby.shellescape} \"$@\"\n")
    write_executable(File.join(@bin_dir, 'pod'), "#!#{RUBY_BIN}\n")
    write_executable(File.join(@fixture_bin, 'pod'), <<~SH)
      #!/bin/sh
      GEM_HOME="#{@gem_home}" exec "#{@bin_dir}/pod" "$@"
    SH
    other_environment = {
      'GEM_HOME' => nil,
      'GEM_PATH' => nil,
      'PATH' => [@fixture_bin, @bin_dir, '/usr/bin', '/bin'].join(File::PATH_SEPARATOR)
    }
    [@bin_dir, File.join(@dir, 'legacy commands')].each do |command_dir|
      FileUtils.mkdir_p(command_dir)
      %w[podx mgit].each do |name|
        destination = File.join(command_dir, name)
        FileUtils.cp(File.join(installed_dir, 'bin', name), destination)
        stdout = run_success(destination, '--help', env: other_environment)
        assert_includes stdout, name == 'podx' ? 'podx install' : 'mgit branch'
      end
      assert_equal "cocoapods-podx #{@version}\n",
                   run_success(File.join(command_dir, 'podx'), '--version', env: other_environment)
    end
  end

  def test_upgrade_refreshes_the_command_directory_and_can_be_reinstalled
    install_gem(build_gem)
    next_version = Gem::Version.new(@version).bump.to_s
    gemspec = File.join(@source, 'cocoapods-podx.gemspec')
    File.write(gemspec, File.read(gemspec).sub(/spec\.version\s*=\s*["'][^"']+["']/, "spec.version = #{next_version.inspect}"))
    package = build_gem(next_version)
    run_success(File.join(@bin_dir, 'podx'), 'upgrade', next_version, env: { 'PODX_TEST_GEM_FILE' => package })
    assert_commands_work(next_version)
    %w[podx mgit].each do |name|
      run_success(RUBY_BIN, '-c', File.join(installed_dir(next_version), 'bin', name))
      assert_equal File.read(File.join(@source, 'lib', 'cocoapods_podx', 'shims', name)),
                   File.read(File.join(installed_dir(next_version), 'lib', 'cocoapods_podx', 'shims', name))
    end
    install_gem(package)
    assert_commands_work(next_version)
  end

  private

  def write_executable(path, content)
    File.write(path, content)
    FileUtils.chmod(0o755, path)
  end

  def capture(*command, env: {}, chdir: @dir)
    Open3.capture3(@env.merge(env), *command, chdir: chdir)
  end

  def run_success(*command, **options)
    stdout, stderr, status = capture(*command, **options)
    assert status.success?, "#{command.shelljoin}\n#{stdout}\n#{stderr[0, 6000]}"
    stdout
  end

  def build_gem(version = @version)
    run_success(RUBY_BIN, GEM_BIN, 'build', 'cocoapods-podx.gemspec', chdir: @source)
    File.join(@source, "cocoapods-podx-#{version}.gem")
  end

  def install_gem(package)
    run_success(RUBY_BIN, GEM_BIN, 'install', '--local', '--ignore-dependencies', '--force', '--no-document', package)
  end

  def installed_dir(version = @version)
    File.join(@gem_home, 'gems', "cocoapods-podx-#{version}")
  end

  def assert_commands_work(version)
    assert_equal "cocoapods-podx #{version}\n", run_success(File.join(@bin_dir, 'podx'), '--version')
    assert_includes run_success(File.join(@bin_dir, 'podx'), '--help'), 'podx install'
    assert_includes run_success(File.join(@bin_dir, 'mgit'), '--help'), 'mgit branch'
  end
end
