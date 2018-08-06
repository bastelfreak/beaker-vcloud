require 'spec_helper'

module Beaker
  describe Vcloud do

    before :each do
      MockVsphereHelper.set_config( fog_file_contents )
      MockVsphereHelper.set_vms( make_hosts() )
      stub_const( "VsphereHelper", MockVsphereHelper )
      stub_const( "Net", MockNet )
      json = double( 'json' )
      allow( json ).to receive( :parse ) do |arg|
        arg
      end
      stub_const( "JSON", json )
      allow( Socket ).to receive( :getaddrinfo ).and_return( true )
      allow_any_instance_of( Beaker::Shared ).to receive( :get_fog_credentials ).and_return( fog_file_contents )
      allow_any_instance_of( VsphereHelper ).to receive( :new ).and_return (MockVsphereHelper)
    end

    describe "#provision" do

      it 'warns about deprecated behavior if pooling_api is provided' do
        opts = make_opts
        opts[:pooling_api] = 'testpool'
        expect( opts[:logger] ).to receive( :warn ).once
        expect{ Beaker::Vcloud.new( make_hosts, opts ) }.to raise_error( /datacenter/ )
      end

      it 'does not instantiate vmpooler if pooling_api is provided' do
        opts = make_opts
        opts[:pooling_api] = 'testpool'
        expect{ Beaker::Vcloud.new( make_hosts, opts ) }.to raise_error( /datacenter/ )
      end

      it 'ignores pooling_api and instantiates self' do
        opts = make_opts
        opts[:pooling_api] = 'testpool'
        opts[:datacenter] = 'testdatacenter'
        hypervisor = Beaker::Vcloud.new( make_hosts, opts)
        expect( hypervisor.class ).to be Beaker::Vcloud
      end

      it 'provisions hosts and add them to the pool' do
        MockVsphereHelper.powerOff

        opts = make_opts
        opts[:pooling_api] = nil
        opts[:datacenter] = 'testdc'

        vcloud = Beaker::Vcloud.new( make_hosts, opts )
        allow( vcloud ).to receive( :require ).and_return( true )
        allow( vcloud ).to receive( :sleep ).and_return( true )
        vcloud.provision

        hosts = vcloud.instance_variable_get( :@hosts )
        hosts.each do | host |
          name = host['vmhostname']
          vm = MockVsphereHelper.find_vm( name )
          expect( vm.toolsRunningStatus ).to be === "guestToolsRunning"
        end

      end

      it 'does not run enable_root on cygwin hosts' do
        MockVsphereHelper.powerOff

        opts = make_opts
        opts[:pooling_api] = nil
        opts[:datacenter] = 'testdc'

        hosts = make_hosts
        hosts.each do |host|
          allow( host ).to receive( :is_cygwin? ).and_return( true )
        end
        vcloud = Beaker::Vcloud.new( hosts, opts )
        allow( vcloud ).to receive( :require ).and_return( true )
        allow( vcloud ).to receive( :sleep ).and_return( true )
        expect( vcloud ).to receive( :enable_root ).never
        vcloud.provision

      end

    end

    describe "#cleanup" do

      it "cleans up hosts not in the pool" do
        MockVsphereHelper.powerOn

        opts = make_opts
        opts[:pooling_api] = nil
        opts[:datacenter] = 'testdc'

        vcloud = Beaker::Vcloud.new( make_hosts, opts )
        allow( vcloud ).to receive( :require ).and_return( true )
        allow( vcloud ).to receive( :sleep ).and_return( true )
        vcloud.provision
        vcloud.cleanup

        hosts = vcloud.instance_variable_get( :@hosts )
        vm_names = hosts.map {|h| h['vmhostname'] }.compact
        vm_names.each do | name |
          vm = MockVsphereHelper.find_vm( name )
          expect( vm.runtime.powerState ).to be === "poweredOff"
        end

      end

    end

  end

end
