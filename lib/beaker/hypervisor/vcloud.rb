require 'yaml' unless defined?(YAML)
require 'beaker/hypervisor/vsphere_helper'
require 'rbvmomi'

module Beaker
  class Vcloud < Beaker::Hypervisor
    def self.new(vcloud_hosts, options)
      # Warning for pre-vmpooler style hosts configuration. TODO: remove this eventually.
      if options['pooling_api'] && !options['datacenter']
        options[:logger].warn 'It looks like you may be trying to access vmpooler with `hypervisor: vcloud`. ' \
                              'This functionality has been removed. Change your hosts to `hypervisor: vmpooler` ' \
                              'and remove unused :datacenter, :folder, and :datastore from CONFIG.'
      end
      super
    end

    def initialize(vcloud_hosts, options)
      @options = options
      @logger = options[:logger]
      @hosts = vcloud_hosts

      raise 'You must specify a datastore for vCloud instances!' unless @options['datastore']
      raise 'You must specify a folder for vCloud instances!' unless @options['folder']
      raise 'You must specify a datacenter for vCloud instances!' unless @options['datacenter']

      @vcenter_credentials = get_fog_credentials(@options[:dot_fog], @options[:vcenter_instance] || :default)
    end

    def connect_to_vsphere
      @logger.notify "Connecting to vSphere at #{@vcenter_credentials[:vsphere_server]}" +
                     " with credentials for #{@vcenter_credentials[:vsphere_username]}"

      @vsphere_helper = VsphereHelper.new server: @vcenter_credentials[:vsphere_server],
                                          user: @vcenter_credentials[:vsphere_username],
                                          pass: @vcenter_credentials[:vsphere_password]
    end

    def wait_for_dns_resolution(host, try, attempts)
      @logger.notify "Waiting for #{host['vmhostname']} DNS resolution"
      begin
        Socket.getaddrinfo(host['vmhostname'], nil)
      rescue StandardError
        raise "DNS resolution failed after #{@options[:timeout].to_i} seconds" unless try <= attempts

        sleep 5
        try += 1

        retry
      end
    end

    def booting_host(host, try, attempts)
      @logger.notify "Booting #{host['vmhostname']} (#{host.name}) and waiting for it to register with vSphere"
      until @vsphere_helper.find_vms(host['vmhostname'])[host['vmhostname']].summary.guest.toolsRunningStatus == 'guestToolsRunning' and
            !@vsphere_helper.find_vms(host['vmhostname'])[host['vmhostname']].summary.guest.ipAddress.nil?
        raise "vSphere registration failed after #{@options[:timeout].to_i} seconds" unless try <= attempts

        sleep 5
        try += 1

      end
    end

    # Directly borrowed from openstack hypervisor
    def enable_root(host)
      return unless host['user'] != 'root'

      copy_ssh_to_root(host, @options)
      enable_root_login(host, @options)
      host['user'] = 'root'
      host.close
    end

    def create_clone_spec(host)
      # Add VM annotation
      additionalExtraConfig = if host['extraConfig']
                                host['extraConfig'].map do |key, value|
                                  { key: key, value: value }
                                end
                              else
                                []
                              end
      extraConfig = [{ key: 'guestinfo.hostname', value: host['vmhostname'] }] + additionalExtraConfig
      @logger.debug("#{host['vmhostname']}: extraConfig is: #{extraConfig}")
      configSpec = RbVmomi::VIM.VirtualMachineConfigSpec(
        annotation: 'Base template:  ' + host['template'] + "\n" +
          'Creation time:  ' + Time.now.strftime('%Y-%m-%d %H:%M') + "\n\n" +
          'CI build link:  ' + (ENV['BUILD_URL'] || 'Deployed independently of CI') +
          'department:     ' + @options[:department] +
          'project:        ' + @options[:project],
        extraConfig: extraConfig,
      )

      # Are we using a customization spec?
      customizationSpec = @vsphere_helper.find_customization(host['template'])

      if customizationSpec
        # Print a logger message if using a customization spec
        @logger.notify "Found customization spec for '#{host['template']}', will apply after boot"
      end

      # Put the VM in the specified folder and resource pool
      relocateSpec = RbVmomi::VIM.VirtualMachineRelocateSpec(
        datastore: @vsphere_helper.find_datastore(@options['datacenter'], @options['datastore']),
        pool: if @options['resourcepool']
                @vsphere_helper.find_pool(@options['datacenter'],
                                          @options['resourcepool'])
              end,
        diskMoveType: :moveChildMostDiskBacking,
      )

      # Create a clone spec
      RbVmomi::VIM.VirtualMachineCloneSpec(
        config: configSpec,
        location: relocateSpec,
        customization: customizationSpec,
        powerOn: true,
        template: false,
      )
    end

    def provision
      connect_to_vsphere
      begin
        try = 1
        attempts = @options[:timeout].to_i / 5

        start = Time.now
        tasks = []
        @hosts.each_with_index do |h, _i|
          h['vmhostname'] = (h['name'] || generate_host_name)

          if h['template'].nil? and defined?(ENV.fetch('BEAKER_vcloud_template', nil))
            h['template'] = ENV.fetch('BEAKER_vcloud_template', nil)
          end

          unless h['template']
            raise "Missing template configuration for #{h}.  Set template in nodeset or set ENV[BEAKER_vcloud_template]"
          end

          if %r{/}.match?(h['template'])
            templatefolders = h['template'].split('/')
            h['template'] = templatefolders.pop
          end

          @logger.notify "Deploying #{h['vmhostname']} (#{h.name}) to #{@options['folder']} from template '#{h['template']}'"

          vm = {}

          if templatefolders
            vm[h['template']] =
              @vsphere_helper.find_folder(@options['datacenter'], templatefolders.join('/')).find(h['template'])
          else
            vm = @vsphere_helper.find_vms(h['template'])
          end

          raise "Unable to find template '#{h['template']}'!" if vm.length == 0

          spec = create_clone_spec(h)

          # Deploy from specified template
          tasks << vm[h['template']].CloneVM_Task(
            folder: @vsphere_helper.find_folder(@options['datacenter'],
                                                @options['folder']), name: h['vmhostname'], spec: spec
          )
        end

        try = (Time.now - start) / 5
        @vsphere_helper.wait_for_tasks(tasks, try, attempts)
        @logger.notify format('Spent %.2f seconds deploying VMs', (Time.now - start))

        try = (Time.now - start) / 5
        duration = run_and_report_duration do
          @hosts.each_with_index do |h, _i|
            booting_host(h, try, attempts)
          end
        end
        @logger.notify 'Spent %.2f seconds booting and waiting for vSphere registration' % duration

        try = (Time.now - start) / 5
        duration = run_and_report_duration do
          @hosts.each do |host|
            repeat_fibonacci_style_for 8 do
              !@vsphere_helper.find_vms(host['vmhostname'])[host['vmhostname']].summary.guest.ipAddress.nil?
            end
            host[:ip] = @vsphere_helper.find_vms(host['vmhostname'])[host['vmhostname']].summary.guest.ipAddress
            enable_root(host) unless host.is_cygwin?
          end
        end

        @logger.notify 'Spent %.2f seconds waiting for DNS resolution' % duration
      rescue StandardError => e
        @vsphere_helper.close
        report_and_raise(@logger, e, 'Vcloud.provision')
      end
    end

    def cleanup
      @logger.notify 'Destroying vCloud boxes'
      connect_to_vsphere

      vm_names = @hosts.map { |h| h['vmhostname'] }.compact
      if @hosts.length != vm_names.length
        @logger.warn 'Some hosts did not have vmhostname set correctly! This likely means VM provisioning was not successful'
      end
      vms = @vsphere_helper.find_vms vm_names
      begin
        vm_names.each do |name|
          unless vm = vms[name]
            @logger.warn "Unable to cleanup #{name}, couldn't find VM #{name} in vSphere!"
            next
          end

          if vm.runtime.powerState == 'poweredOn'
            @logger.notify "Shutting down #{vm.name}"
            duration = run_and_report_duration do
              vm.PowerOffVM_Task.wait_for_completion
            end
            @logger.notify "Spent %.2f seconds halting #{vm.name}" % duration
          end

          duration = run_and_report_duration do
            vm.Destroy_Task
          end
          @logger.notify "Spent %.2f seconds destroying #{vm.name}" % duration
        end
      rescue RbVmomi::Fault => e
        if e.fault.is_a?(RbVmomi::VIM::ManagedObjectNotFound)
          # it's already gone, don't bother trying to delete it
          name = vms.key(e.fault.obj)
          vms.delete(name)
          vm_names.delete(name)
          @logger.warn "Unable to destroy #{name}, it was not found in vSphere"
          retry
        end
      end
      @vsphere_helper.close
    end
  end
end
