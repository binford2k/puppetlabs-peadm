# @api private
plan peadm::subplans::modify_cert_extensions (
  Peadm::SingleTargetSpec $targets,
  TargetSpec              $primary_host,
  String                  $primary_certname,
  Hash                    $add = { },
  Array                   $remove = [ ],
) {
  $target = get_target($targets)
  $primary_target = get_target($primary_host)

  # This plan doesn't work to reissue the master cert over the orchestrator due
  # to pe-puppetserver needing to restart
  if ($primary_target == $target) {
    $primary_target.peadm::fail_on_transport('pcp')
  }

  # Figure out some information from the existing certificate
  $certdata = run_task('peadm::cert_data', $target).first.value
  $certname = $certdata['certname']
  $target_is_primary = ($certname == $primary_certname)

  # These vars represent what the extensions currently are, vs. what they should be
  $existing_exts = $certdata['extensions'].filter |$k,$v| { $k =~ /^1\.3\.6\.1\.4\.1\.34380\.1(?!\.3\.39)/ }
  $desired_exts = $existing_exts.filter |$k,$v| { !($k in $remove) } + $add

  # If the existing certificate meets all the requirements, there's no need
  # to regenerate it. Skip it and move on to the next.
  if ($certdata['certificate-exists']
      and ($desired_exts.all |$key,$val| { $existing_exts[$key] == $val })
      and !($remove.any |$key| { $key in $existing_exts.keys })) {
    out::message("${certname} already has requested extensions; certificate will not be re-issued")
    return('Skipped')
  }

  # Everything starts the same; we always stop the agent and revoke the
  # existing cert. We use `run_command` in case the master is 2019.x but
  # the agent is only 2018.x. In that scenario `run_task(service, ...)`
  # doesn't work.
  $was_running = run_command('systemctl is-active puppet.service', $target, _catch_errors => true)[0].ok
  if ($was_running) { run_command('systemctl stop puppet.service', $target) }

  # Make sure the csr_attributes.yaml file on the node matches
  run_plan('peadm::util::insert_csr_extension_requests', $target,
    extension_requests => $desired_exts,
    merge              => false,
  )

  $ca_clean_result = run_command(@("HEREDOC"/L), $primary_target, _catch_errors =>  true).first
    /opt/puppetlabs/bin/puppetserver ca clean --certname ${certname}
    |-HEREDOC

  unless $ca_clean_result.ok {
    # fail the plan unless it's a known circumstance in which it's okay to proceed.
    # Scenario 1: the primary's cert can't be cleaned because it's already revoked.
    # Scenario 2: the primary's cert can't be cleaned because it's been deleted.
    unless ($target_is_primary and (
              $ca_clean_result[merged_output] =~ /certificate revoked/ or
              $ca_clean_result[merged_output] =~ /Could not find 'hostcert'/)) {
      fail_plan($ca_clean_result)
    }
  }

  # Then things get different for clients vs. primary...
  unless ($target_is_primary) {
    # CLIENT cert regeneration
    run_task('peadm::ssl_clean', $target, certname => $certname)
    run_task('peadm::submit_csr', $target)
    run_task('peadm::sign_csr', $primary_target, certnames => [$certname])

    # Use a command instead of a task so that this works for Puppet 5 agents
    # w/ PCP transport. If using a task, we run into problems downloading
    # the task file at this point, because there is no longer a cert file
    # present on the agent.
    run_command(@("HEREDOC"/L), $target)
      /opt/puppetlabs/bin/puppet ssl download_cert --certname ${certname} || \
      /opt/puppetlabs/bin/puppet certificate find --ca-location remote ${certname}
      |-HEREDOC
  }
  else {
    # PRIMARY cert regeneration
    $alt_names = $certdata['dns-alt-names'].empty ? {
      true  => $certdata['certname'],
      false => $certdata['dns-alt-names'].join(','),
    }

    # The docs are broken, and the process is unclean. Sadface.
    run_task('service', $target, {action => 'stop', name => 'pe-puppetserver'})
    run_command(@("HEREDOC"/L), $target)
      rm -f \
        /etc/puppetlabs/puppet/ssl/certs/${certname}.pem \
        /etc/puppetlabs/puppet/ssl/private_keys/${certname}.pem \
        /etc/puppetlabs/puppet/ssl/public_keys/${certname}.pem \
        /etc/puppetlabs/puppet/ssl/certificate_requests/${certname}.pem \
        /etc/puppetlabs/puppet/ssl/ca/signed/${certname}.pem \
      |-HEREDOC
    run_command(@("HEREDOC"/L), $target)
      /opt/puppetlabs/bin/puppetserver ca generate \
        --certname ${certname} \
        --subject-alt-names ${alt_names} \
        --ca-client
      |-HEREDOC
    run_task('service', $target, {action => 'start', name => 'pe-puppetserver'})
  }

  # Fire puppet back up when done
  if ($was_running) { run_command('systemctl start puppet.service', $target) }

  # Get PuppetDB trusted fact information back up to date
  run_command('/opt/puppetlabs/bin/puppet facts upload', $target)
}
