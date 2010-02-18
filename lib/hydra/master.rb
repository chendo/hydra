require 'hydra/hash'
require 'open3'
require 'tmpdir'
module Hydra #:nodoc:
  # Hydra class responsible for delegate work down to workers.
  #
  # The Master is run once for any given testing session.
  class Master
    include Hydra::Messages::Master
    include Open3
    traceable('MASTER')
    # Create a new Master
    #
    # Options:
    # * :files
    #   * An array of test files to be run. These should be relative paths from
    #     the root of the project, since they may be run on different machines
    #     which may have different paths.
    # * :workers
    #   * An array of hashes. Each hash should be the configuration options
    #     for a worker.
    def initialize(opts = { })
      opts.stringify_keys!
      config_file = opts.delete('config') { nil }
      if config_file
        opts.merge!(YAML.load_file(config_file).stringify_keys!)
      end
      @files = Array(opts.fetch('files') { nil })
      raise "No files, nothing to do" if @files.empty?
      @incomplete_files = @files.dup
      @workers = []
      @listeners = []
      @verbose = opts.fetch('verbose') { false }
      @report = opts.fetch('report') { false }
      @autosort = opts.fetch('autosort') { true }
      sort_files_from_report if @autosort
      init_report_file
      @sync = opts.fetch('sync') { nil }

      # default is one worker that is configured to use a pipe with one runner
      worker_cfg = opts.fetch('workers') { [ { 'type' => 'local', 'runners' => 1} ] }

      trace "Initialized"
      trace "  Files:   (#{@files.inspect})"
      trace "  Workers: (#{worker_cfg.inspect})"
      trace "  Verbose: (#{@verbose.inspect})"

      boot_workers worker_cfg
      process_messages
    end

    # Message handling
    
    # Send a file down to a worker. 
    def send_file(worker)
      f = @files.shift
      if f
        trace "Sending #{f.inspect}"
        report_start_time(f)
        worker[:io].write(RunFile.new(:file => f))
      else
        trace "No more files to send"
      end
    end

    # Process the results coming back from the worker.
    def process_results(worker, message)
      $stdout.write message.output
      # only delete one
      @incomplete_files.delete_at(@incomplete_files.index(message.file))
      trace "#{@incomplete_files.size} Files Remaining"
      report_finish_time(message.file)
      if @incomplete_files.empty?
        shutdown_all_workers
      else
        send_file(worker)
      end
    end

    # A text report of the time it took to run each file
    attr_reader :report_text

    private
    
    def boot_workers(workers)
      trace "Booting #{workers.size} workers"
      workers.each do |worker|
        worker.stringify_keys!
        trace "worker opts #{worker.inspect}"
        type = worker.fetch('type') { 'local' }
        if type.to_s == 'local'
          boot_local_worker(worker)
        elsif type.to_s == 'ssh'
          @workers << worker # will boot later, during the listening phase
        else
          raise "Worker type not recognized: (#{type.to_s})"
        end
      end
    end

    def boot_local_worker(worker)
      runners = worker.fetch('runners') { raise "You must specify the number of runners" }
      trace "Booting local worker" 
      pipe = Hydra::Pipe.new
      child = SafeFork.fork do
        pipe.identify_as_child
        Hydra::Worker.new(:io => pipe, :runners => runners, :verbose => @verbose)
      end
      pipe.identify_as_parent
      @workers << { :pid => child, :io => pipe, :idle => false, :type => :local }
    end

    def boot_ssh_worker(worker)
      runners = worker.fetch('runners') { raise "You must specify the number of runners"  }
      connect = worker.fetch('connect') { raise "You must specify an SSH connection target" }
      ssh_opts = worker.fetch('ssh_opts') { "" }
      directory = worker.fetch('directory') { raise "You must specify a remote directory" }
      command = worker.fetch('command') { 
        "ruby -e \"require 'rubygems'; require 'hydra'; Hydra::Worker.new(:io => Hydra::Stdio.new, :runners => #{runners}, :verbose => #{@verbose});\""
      }

      if @sync
        @sync.stringify_keys!
        trace "Synchronizing with #{connect}\n\t#{@sync.inspect}"
        local_dir = @sync.fetch('directory') { 
          raise "You must specify a synchronization directory"
        }
        exclude_paths = @sync.fetch('exclude') { [] }
        exclude_opts = exclude_paths.inject(''){|memo, path| memo += "--exclude=#{path} "}

        rsync_command = [
          'rsync',
          '-avz',
          '--delete',
          exclude_opts,
          File.expand_path(local_dir)+'/',
          "-e \"ssh #{ssh_opts}\"",
          "#{connect}:#{directory}"
        ].join(" ")
        trace rsync_command
        trace `#{rsync_command}`
      end

      trace "Booting SSH worker" 
      ssh = Hydra::SSH.new("#{ssh_opts} #{connect}", directory, command)
      return { :io => ssh, :idle => false, :type => :ssh }
    end

    def shutdown_all_workers
      trace "Shutting down all workers"
      @workers.each do |worker|
        worker[:io].write(Shutdown.new) if worker[:io]
        worker[:io].close if worker[:io] 
      end
      @listeners.each{|t| t.exit}
    end

    def process_messages
      Thread.abort_on_exception = true

      trace "Processing Messages"
      trace "Workers: #{@workers.inspect}"
      @workers.each do |worker|
        @listeners << Thread.new do
          trace "Listening to #{worker.inspect}"
           if worker.fetch('type') { 'local' }.to_s == 'ssh'
             worker = boot_ssh_worker(worker)
             @workers << worker
           end
          while true
            begin
              message = worker[:io].gets
              trace "got message: #{message}"
              # if it exists and its for me.
              # SSH gives us back echoes, so we need to ignore our own messages
              if message and !message.class.to_s.index("Worker").nil?
                message.handle(self, worker) 
              end
            rescue IOError
              trace "lost Worker [#{worker.inspect}]"
              Thread.exit
            end
          end
        end
      end
      
      @listeners.each{|l| l.join}

      generate_report
    end

    def init_report_file
      FileUtils.rm_f(report_file)
      FileUtils.rm_f(report_results_file)
    end

    def report_start_time(file)
      File.open(report_file, 'a'){|f| f.write "#{file}|start|#{Time.now.to_f}\n" }
    end

    def report_finish_time(file)
      File.open(report_file, 'a'){|f| f.write "#{file}|finish|#{Time.now.to_f}\n" }
    end

    def generate_report
      report = {}
      lines = nil
      File.open(report_file, 'r'){|f| lines = f.read.split("\n")}
      lines.each{|l| l = l.split('|'); report[l[0]] ||= {}; report[l[0]][l[1]] = l[2]}
      report.each{|file, times| report[file]['duration'] = times['finish'].to_f - times['start'].to_f}
      report = report.sort{|a, b| b[1]['duration'] <=> a[1]['duration']}
      output = []
      report.each{|file, times| output << "%.2f\t#{file}" % times['duration']}
      @report_text = output.join("\n")
      File.open(report_results_file, 'w'){|f| f.write @report_text}
      return report_text
    end

    def reported_files
      return [] unless File.exists?(report_results_file)
      rep = []
      File.open(report_results_file, 'r') do |f|
        lines = f.read.split("\n")
        lines.each{|l| rep << l.split(" ")[1] }
      end
      return rep
    end

    def sort_files_from_report
      sorted_files = reported_files
      reported_files.each do |f|
        @files.push(@files.delete_at(@files.index(f))) if @files.index(f)
      end
    end

    def report_file
      @report_file ||= File.join(Dir.tmpdir, 'hydra_report.txt')
    end

    def report_results_file
      @report_results_file ||= File.join(Dir.tmpdir, 'hydra_report_results.txt')
    end
  end
end
