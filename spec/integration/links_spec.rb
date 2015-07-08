require 'spec_helper'

describe 'Links', type: :integration do
  with_reset_sandbox_before_each

  def upload_links_release
    FileUtils.cp_r(LINKS_RELEASE_TEMPLATE, ClientSandbox.links_release_dir, :preserve => true)
    bosh_runner.run_in_dir('create release --force', ClientSandbox.links_release_dir)
    bosh_runner.run_in_dir('upload release', ClientSandbox.links_release_dir)
  end

  before do
    target_and_login
    upload_links_release
    upload_stemcell
    cloud_config_hash = Bosh::Spec::Deployments.simple_cloud_config
    cloud_config_hash['networks'].first['subnets'].first['static'] = ['192.168.1.10', '192.168.1.11', '192.168.1.12']
    cloud_config_hash['networks'] << {
      'name' => 'dynamic-network',
      'type' => 'dynamic'
    }

    upload_cloud_config(cloud_config_hash: cloud_config_hash)
  end

  context 'when job requires link' do
    let(:api_job_spec) { Bosh::Spec::Deployments.simple_job(name: 'my_api', templates: [{'name' => 'api_server', 'links' => links}], instances: 1) }

    let(:mysql_job_spec) do
      job_spec = Bosh::Spec::Deployments.simple_job(
        name: 'mysql',
        templates: [{'name' => 'database'}],
        instances: 2,
        static_ips: ['192.168.1.10', '192.168.1.11']
      )
      job_spec['networks'] << {
        'name' => 'dynamic-network',
        'default' => ['dns', 'gateway']
      }
      job_spec
    end

    let(:postgres_job_spec) do
      Bosh::Spec::Deployments.simple_job(
        name: 'postgres',
        templates: [{'name' => 'database'}],
        instances: 1,
        static_ips: ['192.168.1.12']
      )
    end

    let(:manifest) do
      manifest = Bosh::Spec::NetworkingManifest.deployment_manifest
      manifest['jobs'] = [api_job_spec, mysql_job_spec, postgres_job_spec]
      manifest
    end

    context 'when link is not provided' do
      let(:links) { {} }

      it 'raises an error' do
        _, exit_code = deploy_simple_manifest(manifest_hash: manifest, failure_expected: true, return_exit_code: true)
        expect(exit_code).to_not eq(0)
      end
    end

    context 'when link is provided' do
      context 'when link reference source that provides link' do
        let(:links) do
          {
            'db' => 'simple.mysql.database.db',
            'backup_db' => 'simple.postgres.database.backup_db'
          }
        end

        it 'renders link data in job template' do
          deploy_simple_manifest(manifest_hash: manifest)

          link_vm = director.vm('my_api/0')
          template = YAML.load(link_vm.read_job_template('api_server', 'config.yml'))

          expect(template['databases']['main'].size).to eq(2)
          expect(template['databases']['main']).to contain_exactly(
            {
              'name' => 'mysql',
              'index' => 0,
              'networks' => [
                {
                  'name' => 'a',
                  'address' => '192.168.1.10',
                },
                {
                  'name' => 'dynamic-network',
                  'address' => '0.mysql.dynamic-network.simple.bosh'
                }
              ]
            },
            {
              'name' => 'mysql',
              'index' => 1,
              'networks' => [
                {
                  'name' => 'a',
                  'address' => '192.168.1.11',
                },
                {
                  'name' => 'dynamic-network',
                  'address' => '1.mysql.dynamic-network.simple.bosh'
                }
              ]
            }
          )

          expect(template['databases']['backup']).to contain_exactly(
              {
                'name' => 'postgres',
                'index' => 0,
                'networks' => [
                  {
                    'name' => 'a',
                    'address' => '192.168.1.12',
                  }
                ]
              }
            )
        end
      end

      context 'when link reference source that does not provide link' do
        let(:links) { {'db' => 'X.Y.Z.ZZ'} }

        it 'raises an error' do
          _, exit_code = deploy_simple_manifest(manifest_hash: manifest, failure_expected: true, return_exit_code: true)
          expect(exit_code).to_not eq(0)
        end
      end
    end
  end
end
