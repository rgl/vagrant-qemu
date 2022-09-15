require 'securerandom'

require "vagrant/util/busy"
require "vagrant/util/subprocess"

require_relative "plugin"

module VagrantPlugins
  module QEMU
	  class Driver
      # @return [String] VM ID
      attr_reader :vm_id
      attr_reader :data_dir
      attr_reader :tmp_dir

      def initialize(id, dir, tmp)
        @vm_id = id
        @data_dir = dir
        @tmp_dir = tmp.join("vagrant-qemu")
      end

      def get_current_state
        case
        when running?
          :running
        when created?
          :stopped
        else
          :not_created
        end
      end

      def delete
        if created?
          id_dir = @data_dir.join(@vm_id)
          FileUtils.rm_rf(id_dir)
          id_tmp_dir = @tmp_dir.join(@vm_id)
          FileUtils.rm_rf(id_tmp_dir)
        end
      end

      def start(options)
        if !running?
          id_dir = @data_dir.join(@vm_id)
          image_path = id_dir.join("linked-box.img").to_s
          pid_file = id_dir.join("qemu.pid").to_s

          id_tmp_dir = @tmp_dir.join(@vm_id)
          FileUtils.mkdir_p(id_tmp_dir)

          control_socket = ""
          if !options[:control_port].nil?
            control_socket = "port=#{options[:control_port]},host=localhost,ipv4=on"
          else
            unix_socket_path = id_tmp_dir.join("qemu_socket").to_s
            control_socket = "path=#{unix_socket_path}"
          end

          debug_socket = ""
          if !options[:debug_port].nil?
            debug_socket = "port=#{options[:debug_port]},host=localhost,ipv4=on"
          else
            unix_socket_serial_path = id_tmp_dir.join("qemu_socket_serial").to_s
            debug_socket = "path=#{unix_socket_serial_path}"
          end

          cmd = []
          cmd += %W(qemu-system-#{options[:arch]})

          # basic
          cmd += %W(-machine #{options[:machine]})
          cmd += %W(-cpu #{options[:cpu]})
          cmd += %W(-smp #{options[:smp]})
          cmd += %W(-m #{options[:memory]})
          cmd += %W(-device #{options[:net_device]},netdev=net0)

          # ports
          hostfwd = "hostfwd=tcp::#{options[:ssh_port]}-:22"
          options[:ports].each do |v|
            hostfwd += ",hostfwd=#{v}"
          end
          extra_netdev = ""
          if !options[:extra_netdev_args].nil?
            extra_netdev = ",#{options[:extra_netdev_args]}"
          end
          cmd += %W(-netdev user,id=net0,#{hostfwd}#{extra_netdev})

          # drive
          cmd += %W(-drive if=virtio,format=qcow2,file=#{image_path})
          if options[:arch] == "aarch64"
            fm1_path = id_dir.join("edk2-aarch64-code.fd").to_s
            fm2_path = id_dir.join("edk2-arm-vars.fd").to_s
            cmd += %W(-drive if=pflash,format=raw,file=#{fm1_path},readonly=on)
            cmd += %W(-drive if=pflash,format=raw,file=#{fm2_path})
          end

          # control
          cmd += %W(-chardev socket,id=mon0,#{control_socket},server=on,wait=off)
          cmd += %W(-mon chardev=mon0,mode=readline)
          cmd += %W(-chardev socket,id=ser0,#{debug_socket},server=on,wait=off)
          cmd += %W(-serial chardev:ser0)
          cmd += %W(-pidfile #{pid_file})
          cmd += %W(-parallel null -monitor none -display none -vga none)
          if !options[:no_daemonize]
            cmd += %W(-daemonize)
          end

          # user-defined
          cmd += options[:extra_qemu_args]

          execute(*cmd, {:detach => options[:no_daemonize]})
        end
      end

      def stop(options)
        if running?
          if !options[:control_port].nil?
            Socket.tcp("localhost", options[:control_port], connect_timeout: 5) do |sock|
              sock.print "system_powerdown\n"
              sock.close_write
              sock.read
            end
          else
            id_tmp_dir = @tmp_dir.join(@vm_id)
            unix_socket_path = id_tmp_dir.join("qemu_socket").to_s
            Socket.unix(unix_socket_path) do |sock|
              sock.print "system_powerdown\n"
              sock.close_write
              sock.read
            end
         end
        end
      end

      def import(options)
        new_id = SecureRandom.urlsafe_base64(8)

        # Make dir
        id_dir = @data_dir.join(new_id)
        FileUtils.mkdir_p(id_dir)
        id_tmp_dir = @tmp_dir.join(new_id)
        FileUtils.mkdir_p(id_tmp_dir)

        # Prepare firmware
        if options[:arch] == "aarch64"
          execute("cp", options[:qemu_dir].join("edk2-aarch64-code.fd").to_s, id_dir.join("edk2-aarch64-code.fd").to_s)
          execute("cp", options[:qemu_dir].join("edk2-arm-vars.fd").to_s, id_dir.join("edk2-arm-vars.fd").to_s)
        end

        # Create image
        execute("qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", options[:image_path].to_s, id_dir.join("linked-box.img").to_s)

        server = {
          :id => new_id,
        }
      end

      def created?
        result = @data_dir.join(@vm_id).directory?
      end

      def running?
        pid_file = @data_dir.join(@vm_id).join("qemu.pid")
        return false if !pid_file.file?

        begin
          Process.getpgid(File.read(pid_file).to_i)
          true
        rescue Errno::ESRCH
          false
        end
      end

      def execute(*cmd, **opts, &block)
        # Append in the options for subprocess
        cmd << { notify: [:stdout, :stderr, :stdin], :detach => opts[:detach] }

        interrupted  = false
        int_callback = ->{ interrupted = true }
        result = ::Vagrant::Util::Busy.busy(int_callback) do
          ::Vagrant::Util::Subprocess.execute(*cmd, &block)
        end

        if opts
          if opts[:detach]
            # give it a little time to startup
            sleep 5
            return
          end
        end

        result.stderr.gsub!("\r\n", "\n")
        result.stdout.gsub!("\r\n", "\n")

        if result.exit_code != 0 && !interrupted
          raise Errors::ExecuteError,
            command: cmd.inspect,
            stderr: result.stderr,
            stdout: result.stdout
        end

        if opts
          if opts[:with_stderr]
            return result.stdout + " " + result.stderr
          else
            return result.stdout
          end
        end
      end
    end
  end
end
