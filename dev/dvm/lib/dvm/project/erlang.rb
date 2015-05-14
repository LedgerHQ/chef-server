require_relative "erlang_dep"

module DVM
  class ErlangProject < Project
    attr_reader :rebar_config_path, :project_dir, :relpath, :libpath, :relname, :node
    def initialize(project_name, config)
      super
      # TODO use .lock if available, else use .config
      @rebar_config_path = "#{project_dir}/rebar.config.lock"
      reldir = service['rel-type'] == 'relx' ? "_rel" : "rel"
      @relname = service['rel-name'] ? service['rel-name'] : name
      @relpath = "#{@project_dir}/#{reldir}/#{relname}"
      @service_dir = "/var/opt/opscode/embedded/service/#{service['name']}"
      @libpath =  File.join(@relpath, "lib")
      @node = service['node']
    end

    def parse_deps
      return @deps if @deps
      @deps = {}
      path = File.expand_path("../../../../parse.es", __FILE__)
      # For some reason vim tag browser doesn't like it when
      # eval(`...`) is used.
      result = run_command("#{path} #{@rebar_config_path}")
      eval(result.stdout).each do |name, data|
        @deps[name] = ErlangDep.new(name, File.join(project_dir, "deps") , data, self)
      end
    end

    def is_running?
      `ps waux | grep "host/.*#{name}.*/run_erl"`.split("\n").length > 2 ||
      `ps waux | grep "host/.*#{name}.*/beam.smp"`.split("\n").length > 2
    end

    def start(args, background)
      raise DVMArgumentError, "#{name} appears to be already running. Try 'dvm console oc_erchef', or 'dvm stop oc_erchef'" if is_running?
      # Ensure that our packaged installation isn't running, thereby preventing spewage of startup errors.
      disable_service
      if background
        run_command("bin/#{relname} start", "Starting #{name}", cwd: relpath, env: { "DEVVM" => "1" } )
      else
        exec "cd #{relpath} && bin/#{relname} console"
      end
    end

    def stop()
      raise DVMArgumentError, <<-EOM unless is_running?
"#{name} does not seem to be running from a loaded instance.
If you want to stop the global instance, use chef-server-ctl stop #{service['name']}'"
EOM
      run_command("bin/#{name} stop", "Stopping #{name}", :cwd => relpath)
    end

    def console
      raise "#{name} does not seem to be running from a loaded instance. Use `dvm start #{name}` to start it" unless is_running?
      exec "#{erl_command_base} -remsh #{service["node"]}"
    end

    def loaded?
      return @loaded unless @loaded.nil?
      # If a devrel has been performed on this box, almost everything in the
      # lib directory will actually be a symlink to a valid location on this box.
      # Filter out everything that fits this criteria - if any files remain
      # then a proper devrel has not been performed.
      #
      begin
        files = Dir.entries(libpath)
        if files.length < 4
          @loaded = false
          @loaded
        end
      rescue
        @loaded = false
        return @loaded
      end
      files.reject! do |fname|
        fullpath = File.join(libpath, fname)
       # special cases, not symlinks:
        (fname == "patches" or fname == "." or fname == "..") or
          # all else must be both a symlink and resolve to valid location
          (File.symlink?(fullpath) and (File.file?(fullpath) or File.directory?(fullpath)))

      end
      @loaded = files.length == 0
      @loaded

    end

    def link
      say("Setting up symlinks")
      # Yay project inconsistencies
      base_sv_path = "/var/opt/opscode/#{service["name"]}"
      FileUtils.rm_rf(["#{relpath}/log", "#{relpath}/sys.config", "#{relpath}/etc/sys.config"])
      if File.exists?("#{base_sv_path}/sys.config")
        FileUtils.ln_s("#{base_sv_path}/sys.config", "#{relpath}/sys.config")
      else
        FileUtils.ln_s("#{base_sv_path}/etc/sys.config", "#{relpath}/etc/sys.config")
      end

      FileUtils.ln_s("/var/log/opscode/#{service["name"]}", "#{relpath}/log")
    end

    def do_load(options)
      # TODO: Can we just link in our dev-time dependencies post-build,
      # so that we don't have to declare them as apps in app.src? These are
      # typically sync, builder, eunit , mixer and common_test
      #
      # TODO this can also be wrapped and handled in the base...
      # TODO this makes an assumption that this is NOT anything bundled in our chef-server env.
      if ! project_dir_exists_on_host?(name)
        git = project['git']
        if git
          if git['uri']
            clone(name, git['uri'])
            if git['branch']
              checkout(name, git['branch'])
            end
          end
        else
          raise DVMArgumentError, "Project not available. Clone it onto your host machine, or update the git settings in config.yml."
        end
      end

      raise DVMArgumentError, "Project already loaded. Use --force to proceed." if loaded? and not options[:force]
      run_command("chef-server-ctl stop  #{service['name']}", "Stopping #{service['name']}")
      do_build unless options[:no_build]
      disable_service
      link
      say(HighLine.color("Success! Your project is loaded.", :green))
      say("Start it now:")
      say(HighLine.color("    dvm start #{name} [--background]", :green))
    end

    # TODO these can probably live in Tools so they're useful outside of erlang projects.
    def disable_service
      svname = service['name']
      # Don't worry about stopping things until after our build succeeds...
      FileUtils.touch("/opt/opscode/sv/#{svname}/down")
      run_command("sv x #{service['name']}", "Stopping #{name}")
    end

    def enable_service
      svname = service['name']
      FileUtils.rm("/opt/opscode/sv/#{svname}/down")
      run_command("sv s #{svname}", "Enabling packaged #{name}")
      # TODO sv s should be starting it (it thinks it is) but is not.  Take a look at why
      # this extra step is needed
      run_command("chef-server-ctl start #{svname}", "Starting packaged #{name}")

    end
    def unload
      if File.exists?("#{relpath}/sys.config")
        FileUtils.rm("#{relpath}/sys.config")
      else
        FileUtils.rm("#{relpath}/etc/sys.config")
      end
      FileUtils.rm("#{relpath}/log")
      enable_service
    end

    def do_build
      # TODO currently we only load projects that are maintained by Chef and live in chef-server/src.
      # If this changes, we'll need to support specification of alternative build commands.
      # TODO2: add build.env since only erchef needs use_system_gecode...
      run_command("make -j 4 devvm", "Building...", cwd: project_dir, env: { "USE_SYSTEM_GECODE" => "1"})
    end

    def cover(action, modulename, options)
      runargs, message = case action
                         when 'enable'
                           cover_enable_args(modulename, options)
                         when 'report'
                           cover_report_args(modulename, options)
                         when 'reset'
                           [ [modulename], "Resetting coverage stats for #{modulename}"]
                         when 'disable'
                           [ [], "Disabling coverage for all modules and re-enabling automatic code loading" ]
                         else
                           raise DVMArgumentError, "Valid cover commands are enable, disable, reset, and report."
                         end
       erl_rpc("user_default", "cov_#{action}", runargs, message)
    end

    def cover_enable_args(modulename, options)
      msg = "Important: automatic code loading will be disabled until 'dvm cover #{name} stop' is invoked\n"
      msg << "Enabling coverage for #{modulename}"
      msg = "Enabling coverage for #{modulename}"
      runargs = ["\\\"#{@project_dir}\\\""]
      runargs << modulename
      runargs << options[:with_deps]
      [runargs, msg]
    end

    def cover_report_args(modulename, options)
       msg = "Generating coverage report for #{modulename}"
       out_path = File.join(config['vm']['cover']['base_output_path'], name)
       FileUtils.mkdir_p(out_path)
       runargs = ["\\\"#{out_path}\\\""]
       runargs << modulename
       runargs << options[:raw_output]
       [runargs, msg]
    end

    def update(args)
      # No running check in case we're trying to attach to the global instance
      if args == "pause"
        pause_msg = "Pausing sync on #{node}. This will take effect after any running scans have been completed. \nUse 'dvm update oc_erchef resume' to re-enable automatic updates."
        erl_rpc("user_default", "sync_action", ["pause"], pause_msg)
      elsif args == "resume"
        erl_rpc("user_default", "sync_action", ["go"], "Resuming sync")
      else
        # TODO for those that don't have sync, support using user_defaults:um(mod) for explicit reloading.
        raise DVMArgumentError, "Supported update options are 'pause' and 'resume'"
      end
    end

    def etop
      exec "#{erl_command_base("dvmetop")} -s etop -s erlang halt -output text -sort reductions -lines 25 -node #{service['node']}"
    end

    def erl_rpc(mod, fun, args, message = nil)
      if message.nil?
        message = "[#{node}]: Invoking #{mod}:#{fun}(#{args.join(", ")})"
      else
        message = "[#{node}]: #{message}"
      end
      command = "#{erl_command_base} -noshell -eval \"rpc:call('#{node}', #{mod}, #{fun}, [#{args.join(",")}])\""
      # puts ">> " command
      # exec command
      run_command("#{command} -s erlang halt", message)
    end
    def erl_command_base(myname = "dvm")
      "erl -hidden -name #{myname}@127.0.0.1 -setcookie #{service["cookie"]}"
    end

  end
end
