#
# Author:: Chris Jones <cjones303@bloomberg.net>
# Cookbook Name:: ceph
#
# Copyright 2016, Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Federated version of creating keys and setting up radosgw.

# NOTE: This recipe *MUST* be included in the 'radosgw' recipe and not used as a stand alone recipe!

service_type = node['ceph']['mon']['init_style']

# NOTE: This base_key can also be the bootstrap-rgw key (ceph.keyring) if desired but the default is the admin key. Just change it here.
base_key = "/etc/ceph/#{node['ceph']['cluster']}.client.admin.keyring"

if node['ceph']['pools']['radosgw']['federated_enable']
  Chef::Log.info "RADOSGW - FEDERATED Version..."
  node['ceph']['pools']['radosgw']['federated_zone_instances'].each do | inst |
    keyring = "/etc/ceph/#{node['ceph']['cluster']}.client.radosgw.#{inst['region']}-#{inst['name']}.keyring"

    file "/var/log/radosgw/#{node['ceph']['cluster']}.client.radosgw.#{inst['region']}-#{inst['name']}.log" do
      owner node['ceph']['owner']
      group node['ceph']['group']
    end

    directory "/var/lib/ceph/radosgw/#{node['ceph']['cluster']}-radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']}" do
      owner node['ceph']['owner']
      group node['ceph']['group']
      mode node['ceph']['mode']
      recursive true
      action :create
      not_if "test -d /var/lib/ceph/radosgw/#{node['ceph']['cluster']}-radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']}"
    end

    # If a key exists then this will run
    execute 'write-ceph-radosgw-secret' do
      command lazy { "ceph-authtool #{keyring} --create-keyring --name=client.radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']} --add-key=ceph_chef_radosgw_inst_secret(inst['name'])" }
      creates keyring
      only_if { ceph_chef_radosgw_inst_secret(inst['name']) }
      not_if "test -f #{keyring}"
      sensitive true if Chef::Resource::Execute.method_defined? :sensitive
    end

    # If no key exists then this will run
    execute 'generate-client-radosgw-secret' do
      command <<-EOH
        ceph-authtool --create-keyring #{keyring} -n client.radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']} --gen-key --cap osd 'allow rwx' --cap mon 'allow rw'
        ceph -k #{base_key} auth add client.radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']} -i #{keyring}
      EOH
      creates keyring
      not_if { ceph_chef_radosgw_inst_secret(inst) }
      not_if "test -f #{keyring}"
      notifies :create, "ruby_block[save-radosgw-secret-#{inst['name']}]", :immediately
      sensitive true if Chef::Resource::Execute.method_defined? :sensitive
    end

    # Saves the key to the current node attribute
    ruby_block "save-radosgw-secret-#{inst['name']}" do
      block do
        fetch = Mixlib::ShellOut.new("ceph-authtool #{keyring} --print-key")
        fetch.run_command
        key = fetch.stdout
        ceph_chef_save_radosgw_inst_secret(key.delete!("\n"), inst)
      end
      action :nothing
    end

    # Add the region and zone files and remove the default root pools
    # We only have one region even though it's in a list.
    template "/etc/ceph/#{inst['region']}.json" do
      source 'radosgw-federated-region.json.erb'
    end

    if node['ceph']['pools']['radosgw']['federated_enable_regions_zones']
      # TODO: Need more work here for full region/zone
      execute "create-region-#{inst['region']}" do
        command <<-EOH
          radosgw-admin region set --infile #{inst['region']}.json --name client.radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']}
        EOH
        not_if "radosgw-admin region list | grep #{inst['region']}"
      end

      execute "create-region-#{inst['region']}" do
        command lazy { "rados -p .#{inst['region']}.rgw.root rm region_info.default" }
        ignore_failure true
      end

      execute "create-region-#{inst['region']}" do
        command <<-EOH
          radosgw-admin region default --rgw-region=#{inst['region']} --name client.radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']}
          radosgw-admin regionmap update --name client.radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']}
        EOH
        only_if "radosgw-admin region list | grep #{inst['region']}"
      end

      # TODO: Update the keys for the zones. This will allow each one to sync with the other.
      # ceph_chef_secure_password(20)
      # ceph_chef_secure_password(40)
    end

    # Now the zones
    template "/etc/ceph/#{inst['name']}.json" do
      source 'radosgw-federated-zone.json.erb'
      variables lazy {
        {
          :region => "#{inst['region']}",
          :zone => "#{inst['name']}",
          :secret_key => "",
          :access_key => ""
        }
      }
    end

    # This is only here as part of completeness. The service_type is not really needed because of defaults.
    ruby_block "radosgw-finalize-#{inst['name']}" do
      block do
        ['done', service_type].each do |ack|
          ::File.open("/var/lib/ceph/radosgw/#{node['ceph']['cluster']}-radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']}/#{ack}", 'w').close
        end
      end
      not_if "test -f /var/lib/ceph/radosgw/#{node['ceph']['cluster']}-radosgw.#{node['hostname']}.#{inst['region']}-#{inst['name']}/done"
    end
  end
end
