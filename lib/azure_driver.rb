#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2018, IONe Cloud Project, Support.by                             #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
# -------------------------------------------------------------------------- #

ONE_LOCATION = ENV["ONE_LOCATION"] if !defined?(ONE_LOCATION)

if !ONE_LOCATION
    RUBY_LIB_LOCATION = "/usr/lib/one/ruby" if !defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION      = "/etc/one/" if !defined?(ETC_LOCATION)
else
    RUBY_LIB_LOCATION = ONE_LOCATION + "/lib/ruby" if !defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION      = ONE_LOCATION + "/etc/" if !defined?(ETC_LOCATION)
end

$: << RUBY_LIB_LOCATION

AZ_DRIVER_CONF = "#{ETC_LOCATION}/azure_driver.conf"
AZ_DRIVER_DEFAULT = "#{ETC_LOCATION}/azure_driver.default"

require 'yaml'
require 'ms_rest_azure'
require 'azure_driver/azure_sdk'
require 'opennebula'
require 'VirtualMachineDriver'

require 'azure_driver/wild_vms'

module AzureDriver
    ACTION          = VirtualMachineDriver::ACTION
    POLL_ATTRIBUTE  = VirtualMachineDriver::POLL_ATTRIBUTE
    VM_STATE        = VirtualMachineDriver::VM_STATE

    SECURITY_RULES = {
        "SSH" => {
            "name" => 'SSH',
            "destination_port_range" => '22',
            "priority" => '300'
        },
        "HTTP" => {
            "name" => 'HTTP',
            "destination_port_range" => '80',
            "priority" => '340'
        },
        "HTTPS" => {
            "name" => 'HTTPS',
            "destination_port_range" => '443',
            "priority" => '320'
        },
        "RDP" => {
            "name" => 'RDP',
            "destination_port_range" => '3389',
            "priority" => '360'
        },
        "DEFAULT" => {
            "protocol" => 'TCP',
            "direction" => 'Inbound',
            "source_port_range" => '*',
            "source_address_prefix" => '*',
            "source_address_prefixes" => [],
            "destination_address_prefix" => '*',
            "destination_address_prefixes" => [],
            "source_port_ranges" => [],
            "destination_port_ranges" => []
        }
    }

    class Client < Azure::Profiles::Latest::Client
        def initialize(host)
            @account = YAML::load(File.read(AZ_DRIVER_CONF))
            _regions = @account['regions']
            _az = _regions[host] || _regions['default']
            subscription_id = _az['subscription_id']
            tenant_id = _az['tenant_id']
            client_id = _az['client_id']
            client_secret = _az['client_secret']
            provider = MsRestAzure::ApplicationTokenProvider.new(
                tenant_id, #ENV['AZURE_TENANT_ID'],
                client_id, #ENV['AZURE_CLIENT_ID'],
                client_secret #ENV['AZURE_CLIENT_SECRET']
            )

            credentials = MsRest::TokenCredentials.new(provider)

            @options = {
                tenant_id: tenant_id,
                client_id: client_id,
                client_secret: client_secret,
                subscription_id: subscription_id ,
                 credentials: credentials
            }

            super(@options)
        end
        def auth host = nil
            @options
        end

        ### Virtual Machines ###

        # @param [Hash] opts
        # @option opts [String] :name - 
        # @option opts [String] :rg_name - 
        # @option opts [String] :username - 
        # @option opts [String] :passwd - 
        # @option opts [String] :hostname - 
        # @option opts [String] :plan - 
        # @option opts [String] :location - 
        # @option opts [NetworkProfile] :network_profile - 
        # @option opts [String] :name - 
        def mk_virtual_machine opts = {}
            # Include SDK modules to ease access to compute classes.
            # include Azure::Compute::Profiles::Latest::Mgmt
            # include Azure::Compute::Mgmt::V2018_04_01::Models

            # Create a model for new virtual machine
            props = compute.mgmt.model_classes.virtual_machine.new

            # windows_config = WindowsConfiguration.new
            # windows_config.provision_vmagent = true
            # windows_config.enable_automatic_updates = true

            os_profile = compute.mgmt.model_classes.osprofile.new
            os_profile.computer_name = 'azure-vm'
            os_profile.admin_username = opts[:username]
            os_profile.admin_password = opts[:passwd]
            # os_profile.windows_configuration = windows_config
            os_profile.secrets = []
            props.os_profile = os_profile

            hardware_profile = compute.mgmt.model_classes.hardware_profile.new
            hardware_profile.vm_size = opts[:plan]
            props.hardware_profile = hardware_profile

            # create_storage_profile it is hypotetical helper method which creates storage
            # profile by means of ARM Storage SDK.
            props.storage_profile = opts[:storage_profile]

            # create_storage_profile it is hypotetical helper method which creates network
            # profile my means of ARM Network SDK.
            props.network_profile = opts[:network_profile] # create_network_profile

            props.type = 'Microsoft.Compute/virtualMachines'
            props.location = opts[:location]

            compute.mgmt.virtual_machines.create_or_update(opts[:rg_name], opts[:name], props)
        end
        def rm_virtual_machine rg_name, name, rm_disk = false
            if rm_disk then
                vm = compute.mgmt.virtual_machines.list(rg_name).detect { |vm| vm.name == name }
                disk_name = vm.storage_profile.os_disk.name

                compute.mgmt.virtual_machines.delete rg_name, name
                
                rm_virtual_machine_disk( rg_name, disk_name )
            else
                compute.mgmt.virtual_machines.delete rg_name, name

            end
        end

        ### Getters for VMs ###

        def get_virtual_machine deploy_id
            compute.mgmt.virtual_machines.list_all.detect do |vm|
                vm.vm_id == deploy_id
            end
        end
        def get_virtual_machines_ids resource_group = nil
            params = resource_group.nil? ? ['list_all'] : ['list', resource_group ]
            compute.mgmt.virtual_machines.send( *params ).map { |vm| vm.vm_id }
        end
        def get_virtual_machine_size size_name, location
            compute.mgmt.virtual_machine_sizes.list( location ).value.detect do |size| 
                size.name == size_name
            end
        end
        def get_vm_rg_name vm
            vm.id.split('/')[4]
        end
        def get_vm_name deploy_id
            get_virtual_machine(deploy_id).name
        end
        def get_vm_deploy_id_by_one_id one_id
            compute.mgmt.virtual_machines.list_all.detect do |vm|
                vm.name.include? "one-#{one_id}-"
            end.vm_id
        end

        ### Control Methods ###

        def start_vm deploy_id
            vm = get_virtual_machine deploy_id
            compute.mgmt.virtual_machines.start(get_vm_rg_name(vm), vm.name)
            vm.vm_id
        end
        def stop_vm deploy_id
            vm = get_virtual_machine deploy_id
            compute.mgmt.virtual_machines.power_off(get_vm_rg_name(vm), vm.name)
            vm.vm_id
        end
        def restart_vm deploy_id
            vm = get_virtual_machine deploy_id
            compute.mgmt.virtual_machines.restart(get_vm_rg_name(vm), vm.name)
            vm.vm_id
        end
        def terminate_vm deploy_id, one_vm

            warn = ["Warnings: "]

            az_vm = get_virtual_machine deploy_id
            rg_name = get_vm_rg_name az_vm

            iface_name = az_vm.network_profile.network_interfaces.first.id.split('/').last

            rm_virtual_machine rg_name, az_vm.name, true
            begin
                rm_network_interface rg_name, iface_name
            rescue => e
                warn << "VirtualNetworkInterface #{iface_name} may be not removed"
            end
            begin
                rm_virtual_network rg_name, rg_name + '-vnet'
            rescue => e
                warn << "VirtualNetwork #{rg_name + '-vnet'} may be not removed"
            end
            return warn.size != 1 ? warn.join("\n") : '-'
        end

        ######################


        def generate_storage_profile image, disk_size = 30
            storage_profile = compute.mgmt.model_classes.storage_profile.new

            img_ref = compute.mgmt.model_classes.image_reference.new
            img_ref.publisher = image[:publisher]
            img_ref.offer = image[:name]
            img_ref.sku = image[:version]
            img_ref.version = 'latest'
            storage_profile.image_reference = img_ref

            os_disk = compute.mgmt.model_classes.osdisk.new
            os_disk.disk_size_gb = disk_size
            os_disk.create_option = "FromImage"
            storage_profile.os_disk = os_disk

            storage_profile
        end

        def rm_virtual_machine_disk rg_name, name
            compute.mgmt.disks.delete rg_name, name
        end

        ### Resource groups  ###
        def mk_resource_group name, location

            resource_group = resources.mgmt.model_classes.resource_group.new
            resource_group.location = location

            resources.mgmt.resource_groups.create_or_update(name, resource_group)
        end
        def rm_resource_group name
            resources.mgmt.resource_groups.delete name
        end

        ### Virtual Networks ###
        # @param [Hash] opts
        # @option opts [String] :name - 
        # @option opts [String] :rg_name - 
        # @option opts [String] :subnet - (Optional)
        # @option opts [String] :subnet_prefix - (Optional)
        # @option opts [String] :location - 
        # @option opts [Array] :prefixes - (Optional)
        # @option opts [Array] :dns - (Optional)
        def mk_virtual_network opts = {}

            params = network.mgmt.model_classes.virtual_network.new

            address_space = network.mgmt.model_classes.address_space.new
            address_space.address_prefixes = opts[:spaces] || ['10.0.0.0/16']
            params.address_space = address_space

            dhcp_options = network.mgmt.model_classes.dhcp_options.new
            dhcp_options.dns_servers = opts[:dns] || %w(8.8.8.8 8.8.4.4)
            params.dhcp_options = dhcp_options

            sub = network.mgmt.model_classes.subnet.new
            sub.name = opts[:subnet] || 'default'
            sub.address_prefix = opts[:subnet_prefix] || '10.0.2.0/24'

            params.subnets = [sub]

            params.location = opts[:location]

            vnet = network.mgmt.virtual_networks.create_or_update(opts[:rg_name], opts[:name], params)
            vnet.subnets.first
        end
        def rm_virtual_network rg_name, name
            network.mgmt.virtual_networks.delete rg_name, name
        end
        def mk_network_interface rg_name, name, subnet, location, pub_ip = false, ports = []

            nic = network.mgmt.model_classes.network_interface.new

            ip_conf = network.mgmt.model_classes.network_interface_ipconfiguration.new
            ip_conf.name = rg_name
            ip_conf.subnet = subnet
            ip_conf.public_ipaddress = mk_public_ip(rg_name, name.gsub('-iface', '-ip'), location) if pub_ip
            nic.ip_configurations = [ip_conf]

            nic.network_security_group = mk_nsg rg_name, name.gsub('-iface', '-nsg'), location, allow: ports

            nic.location = location

            network.mgmt.network_interfaces.create_or_update(
                rg_name, name, nic
            )
        end
        def rm_network_interface rg_name, name
            network.mgmt.network_interfaces.delete rg_name, name
        end

        def mk_public_ip rg_name, name, location
            pic = network.mgmt.model_classes.public_ipaddress.new
            pic.location = location

            network.mgmt.public_ipaddresses.create_or_update(
                rg_name, name, pic
            )
        end
        def mk_nsg rg_name, name, location, allow: [], deny: []
            nsg = network.mgmt.model_classes.network_security_group.new
            nsg.location = location
            nsg.security_rules = []
            allow.each do | connetion |
                nsg.security_rules << mk_network_security_rule( AzureDriver::SECURITY_RULES[connetion], 'Allow')
            end
            deny.each do | connetion |
                nsg.security_rules << mk_network_security_rule( AzureDriver::SECURITY_RULES[connetion], 'Deny')
            end

            network.mgmt.network_security_groups.create_or_update(
                rg_name, name, nsg
            )
        end
        def mk_network_security_rule template = {}, access = 'Deny' # | Allow
            nsr = network.mgmt.model_classes.security_rule.new
            AzureDriver::SECURITY_RULES['DEFAULT'].each do | property, value |
                nsr.send("#{property}=", value)
            end
            template.each do | property, value |
                nsr.send("#{property}=", value)
            end
            nsr.access = access

            nsr
        end

        def get_virtual_network name, rg_name

            network.mgmt.virtual_networks.get rg_name, name

        end

        def generate_network_profile iface
            profile = compute.mgmt.model_classes.network_profile.new

            iface_ref = compute.mgmt.model_classes.network_interface_reference.new
            iface_ref.id = iface.id

            profile.network_interfaces = [
                iface_ref
            ]
            profile
        end

        ### Monitoring ###
        def poll deploy_id
            begin
                vm = get_virtual_machine deploy_id
                rg_name = get_vm_rg_name vm
                instance = compute.mgmt.virtual_machines.get(
                    rg_name, vm.name, expand:'instanceView'
                )
        
                cpu = monitor.mgmt.metrics.list(
                    vm.id, metricnames: 'Percentage CPU', result_type: 'Data'
                ).value.first.timeseries.first.data.select { |data| data.average != nil }.last
                cpu = cpu.nil? ? 0 : cpu.average
                
                memory = 768
                nettx = monitor.mgmt.metrics.list(
                    vm.id, metricnames: 'Network In', result_type: 'Data'
                ).value.first.timeseries.first.data.select { |data| data.total != nil }.last
                nettx = nettx.nil? ? 0 : nettx.total

                netrx = monitor.mgmt.metrics.list(
                    vm.id, metricnames: 'Network Out', result_type: 'Data'
                ).value.first.timeseries.first.data.select { |data| data.total != nil }.last
                netrx = netrx.nil? ? 0 : netrx.total

                disk_rbytes = monitor.mgmt.metrics.list(
                    vm.id, metricnames: 'Disk Read Bytes', result_type: 'Data'
                ).value.first.timeseries.first.data.last.total.to_f
                disk_wbytes = monitor.mgmt.metrics.list(
                    vm.id, metricnames: 'Disk Write Bytes', result_type: 'Data'
                ).value.first.timeseries.first.data.last.total.to_f
                disk_riops = monitor.mgmt.metrics.list(
                    vm.id, metricnames: 'Disk Read Operations/Sec', result_type: 'Data'
                ).value.first.timeseries.first.data.select { |data| data.average != nil }.last
                disk_riops = disk_riops.nil? ? 0.0 : disk_riops.average * 60
                
                disk_wiops = monitor.mgmt.metrics.list(
                    vm.id, metricnames: 'Disk Write Operations/Sec', result_type: 'Data'
                ).value.first.timeseries.first.data.select { |data| data.average != nil }.last
                disk_wiops = disk_wiops.nil? ? 0.0 : disk_wiops.average * 60
                
        
                info =  "#{AzureDriver::POLL_ATTRIBUTE[:cpu]}=#{cpu * 10} " \
                        "#{AzureDriver::POLL_ATTRIBUTE[:memory]}=#{memory * 1024} " \
                        "#{AzureDriver::POLL_ATTRIBUTE[:netrx]}=#{netrx} " \
                        "#{AzureDriver::POLL_ATTRIBUTE[:nettx]}=#{nettx} " \
                        "DISKRDBYTES=#{disk_rbytes} " \
                        "DISKWRBYTES=#{disk_wbytes} " \
                        "DISKRDIOPS=#{disk_riops} " \
                        "DISKWRIOPS=#{disk_wiops} " \
                        "RESOURCE_GROUP_NAME=#{rg_name.downcase} " \
                        "MONITORING_TIME=#{Time.now.to_i}"
                
                state = ""
                if !instance
                    state = VM_STATE[:error]
                else
                    state = case instance.instance_view.statuses.last.code.split('/').last
                    when "running", "starting"
                        AzureDriver::VM_STATE[:active]
                    when "stopped", "deallocated"
                        state = VM_STATE[:deleted]
                    else
                        AzureDriver::VM_STATE[:unknown]
                    end
                end
        
        
                info = "#{AzureDriver::POLL_ATTRIBUTE[:state]}=#{state} " + info
        
                return info, { 
                    :cpu => cpu, :memory => memory, 
                    :nettx => nettx, :netrx => netrx, 
                    :disk_rbytes => disk_rbytes, :disk_wbytes => disk_wbytes,
                    :state => state }
        
            rescue => e
            # Unknown state if exception occurs retrieving information from
            # an instance
                "#{POLL_ATTRIBUTE[:state]}=#{VM_STATE[:unknown]} "
            end
        end
    end
end