require 'puppet/provider/package'

Puppet::Type.type(:package).provide(:brew, :parent => Puppet::Provider::Package) do
  desc 'Package management using HomeBrew on OSX'

  confine :operatingsystem => :darwin

  has_feature :installable
  has_feature :uninstallable
  has_feature :upgradeable
  has_feature :versionable

  has_feature :install_options

  commands :brew => ENV.fetch('PUPPET_HOMEBREW_COMMAND', 'brew')
  commands :stat => '/usr/bin/stat'

  def self.execute(cmd, failonfail = false, combine = false)
    brew_cmd = command(:brew)
    owner = stat('-nf', '%Uu', brew_cmd).to_i
    group = stat('-nf', '%Ug', brew_cmd).to_i
    home  = Etc.getpwuid(owner).dir

    if owner == 0
      raise Puppet::ExecutionFailure, "Homebrew does not support installations owned by the \"root\" user. Please check the permissions of #{brew_cmd}"
    end

    # the uid and gid can only be set if running as root
    if Process.uid == 0
      uid = owner
      gid = group
    else
      uid = nil
      gid = nil
    end

    custom_env = {'HOME' => home}
    custom_env['HOMEBREW_CHANGE_ARCH_TO_ARM'] = '1' if Facter.value(:has_arm64)
    cmd = ["arch", "-arm64"].append(cmd) if Facter.value(:has_arm64)

    if Puppet.features.bundled_environment?
      Bundler.with_clean_env do
        super(cmd, :uid => uid, :gid => gid, :combine => combine,
              :custom_environment => custom_env, :failonfail => failonfail)
      end
    else
      super(cmd, :uid => uid, :gid => gid, :combine => combine,
            :custom_environment => custom_env, :failonfail => failonfail)
    end
  end

  def self.instances
    package_list.collect { |hash| new(hash) }
  end

  def execute(*args)
    # This does not return exit codes in puppet <3.4.0
    # See https://projects.puppetlabs.com/issues/2538
    self.class.execute(*args)
  end

  def fix_checksum(files)
    begin
      for file in files
        File.delete(file)
      end
    rescue Errno::ENOENT
      Puppet.warning "Could not remove mismatched checksum files #{files}"
    end

    raise Puppet::ExecutionFailure, "Checksum error for package #{name} in files #{files}"
  end

  def resource_name
    if @resource[:name].match(/^https?:\/\//)
      @resource[:name]
    else
      @resource[:name].downcase
    end
  end

  def install_name
    should = @resource[:ensure].downcase

    case should
    when true, false, Symbol
      resource_name
    else
      "#{resource_name}@#{should}"
    end
  end

  def install_options
    Array(resource[:install_options]).flatten.compact
  end

  def latest
    cmd_line = [command(:brew), :info, '--json', resource_name]
    cmd_output = execute(cmd_line)
    data = JSON.parse(cmd_output, symbolize_names: true)
    if data.count < 1
      uppet.debug "Package #{options[:justme]} not found"
    end
    if data.count > 1
      Puppet.warning "Multiple matches for package #{options[:justme]} - using first one found"
    end
    pkg_data = data[0]
    Puppet.debug "Found package #{pkg_data[:name]}"
    return pkg_data[:versions][:stable]
  end

  def query
    self.class.package_list(:justme => resource_name)
  end

  def do_install
    begin
      output = execute([command(:brew), :install, install_name, *install_options], :failonfail => true)

      if output =~ /sha256 checksum/
        Puppet.debug "Fixing checksum error..."
        mismatched = output.match(/Already downloaded: (.*)/).captures
        fix_checksum(mismatched)
      end

    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not install package: #{detail}"
    end
  end

  def do_upgrade
    begin
      execute([command(:brew), :upgrade, resource_name], :failonfail => true)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not upgrade package: #{detail}"
    end
  end

  def install
    begin
      Puppet.debug "Looking for #{install_name} package..."
      execute([command(:brew), :info, install_name], :failonfail => true)
    rescue Puppet::ExecutionFailure
      raise Puppet::Error, "Could not find package: #{install_name}"
    end

    Puppet.debug "Package found, installing..."
    do_install
  end

  def uninstall
    begin
      Puppet.debug "Uninstalling #{resource_name}"
      execute([command(:brew), :uninstall, resource_name], :failonfail => true)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not uninstall package: #{detail}"
    end
  end

  def update
    if query
      Puppet.debug "Upgrading #{resource_name}"
      do_upgrade
    else
      Puppet.debug "Installing #{resource_name}"
      do_install
    end
  end

  def self.package_list(options={})
    Puppet.debug "Listing installed packages"

    cmd_line = [command(:brew), :list, '--versions']
    if options[:justme]
      cmd_line += [ options[:justme] ]
    end

    begin
      cmd_output = execute(cmd_line)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not list packages: #{detail}"
    end

    # Exclude extraneous lines from stdout that interfere with the parsing
    # logic below.  These look like they should be on stderr anyway based
    # on comparison to other output on stderr.  homebrew bug?
    re_excludes = Regexp.union([
      /^==>.*/,
      /^Tapped \d+ formulae.*/,
      ])
    lines = cmd_output.lines.delete_if { |line| line.match(re_excludes) }

    if options[:justme]
      if lines.empty?
        Puppet.debug "Package #{options[:justme]} not installed"
        return nil
      else
        if lines.length > 1
          Puppet.warning "Multiple matches for package #{options[:justme]} - using first one found"
        end
        line = lines.shift
        Puppet.debug "Found package #{line}"
        return name_version_split(line)
      end
    else
      return lines.map{ |l| name_version_split(l) }
    end
  end

  def self.name_version_split(line)
    if line =~ (/^(\S+)\s+(.+)/)
      {
        :name     => $1,
        :ensure   => $2,
        :provider => :brew
      }
    else
      Puppet.warning "Could not match #{line}"
      nil
    end
  end
end
