require 'spec_helper'

describe 'peadm::install' do
  include BoltSpec::Plans

  def allow_standard_non_returning_calls(params)
    allow_apply
    allow_task('peadm::agent_install')
    allow_task('peadm::ssl_clean')
    allow_task('peadm::submit_csr')
    allow_task('peadm::sign_csr')
    allow_task('peadm::puppet_runonce')
    allow_task('peadm::provision_replica')
    allow_command('systemctl start puppet.service')
    allow_command("puppet infrastructure forget #{params['replica_host']}")
    allow_command("puppet node purge #{params['replica_host']}")
  end

  describe 'basic functionality' do
    let(:params) { { 'primary_host' => 'primary', 'replica_host' => 'replica' } }
    let(:certdata) { { 'certname' => 'primary', 'extensions' => { '1.3.6.1.4.1.34380.1.1.9813' => 'A' } } }

    it 'runs successfully when the primary doesn\'t have alt-names' do
      allow_standard_non_returning_calls(params)
      expect_task('peadm::cert_data').always_return(certdata)
      expect_task('peadm::agent_install')
        .with_params({ 'server'        => 'primary',
                       'install_flags' => [
                         '--puppet-service-ensure', 'stopped',
                         'extension_requests:1.3.6.1.4.1.34380.1.1.9812=puppet/server',
                         'extension_requests:1.3.6.1.4.1.34380.1.1.9813=B',
                         'main:certname=replica',
                         'main:dns_alt_names=replica'
                       ] })

      expect(run_plan('peadm::add_replica', params)).to be_ok
    end

    it 'runs successfully when the primary has alt-names' do
      allow_standard_non_returning_calls(params)
      expect_task('peadm::cert_data').always_return(certdata.merge({ 'dns-alt-names' => ['primary', 'alt'] }))
      expect_task('peadm::agent_install')
        .with_params({ 'server'        => 'primary',
                       'install_flags' => [
                         '--puppet-service-ensure', 'stopped',
                         'extension_requests:1.3.6.1.4.1.34380.1.1.9812=puppet/server',
                         'extension_requests:1.3.6.1.4.1.34380.1.1.9813=B',
                         'main:certname=replica',
                         'main:dns_alt_names=replica,alt'
                       ] })

      expect(run_plan('peadm::add_replica', params)).to be_ok
    end
  end
end
