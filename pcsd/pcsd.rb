require 'sinatra'
require 'rexml/document'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'logger'
require 'thread'
require 'fileutils'
require 'cgi'

require 'bootstrap.rb'
require 'resource.rb'
require 'remote.rb'
require 'fenceagent.rb'
require 'cluster.rb'
require 'config.rb'
require 'pcs.rb'
require 'auth.rb'
require 'cfgsync.rb'
require 'permissions.rb'

use Rack::CommonLogger

set :app_file, __FILE__

def getAuthUser()
  return {
    :username => $tornado_username,
    :usergroups => $tornado_groups,
  }
end

before do
  # nobody is logged in yet
  @auth_user = nil
  @tornado_session_username = $tornado_username
  @tornado_session_groups = $tornado_groups
  @tornado_is_authenticated = $tornado_is_authenticated

  if(request.path.start_with?('/remote/') and request.path != "/remote/auth") or request.path == '/run_pcs'
    # Sets @auth_user to a hash containing info about logged in user or halts
    # the request processing if login credentials are incorrect.
    protect_by_token!
  else
    # Set a sane default: nobody is logged in, but we do not need to check both
    # for nil and empty username (if auth_user and auth_user[:username])
    @auth_user = {} if not @auth_user
  end
  $cluster_name = get_cluster_name()
end

configure do
  PCS = get_pcs_path()
  $logger = configure_logger(StringIO.new())
  $logger.formatter = proc {|severity, datetime, progname, msg|
    # rushing a raw logging info into the global
    $tornado_logs << {
      :level => severity,
      :timestamp_usec => (datetime.to_f * 1000000).to_i,
      :message => msg,
    }
    # don't need any log to the stream
    ""
  }

  capabilities, capabilities_pcsd = get_capabilities($logger)
  CAPABILITIES = capabilities.freeze
  CAPABILITIES_PCSD = capabilities_pcsd.freeze
end

def run_cfgsync
  $logger.debug('Config files sync started')
  if Cfgsync::ConfigSyncControl.sync_thread_allowed?()
    begin
      # do not sync if this host is not in a cluster
      cluster_name = get_cluster_name()
      cluster_nodes = get_corosync_nodes_names()
      if cluster_name and !cluster_name.empty?() and cluster_nodes and !cluster_nodes.empty?
        $logger.debug('Config files sync fetching')
        fetcher = Cfgsync::ConfigFetcher.new(
          PCSAuth.getSuperuserAuth(),
          Cfgsync::get_cfg_classes(),
          cluster_nodes,
          cluster_name
        )
        cfgs_to_save, _ = fetcher.fetch()
        cfgs_to_save.each { |cfg_to_save|
          cfg_to_save.save()
        }
      end
    rescue => e
      $logger.warn("Config files sync exception: #{e}")
    end
  end
  $logger.debug('Config files sync finished')
  return Cfgsync::ConfigSyncControl.sync_thread_interval()
end

helpers do
  def is_ajax?
    return request.env['HTTP_X_REQUESTED_WITH'] == 'XMLHttpRequest'
  end

  def protect_by_token!
    @auth_user = PCSAuth.loginByToken(request.cookies)
    unless @auth_user
      halt [401, '{"notauthorized":"true"}']
    end
  end

  def getParamList(params)
    param_line = []
    meta_options = []
    params.each { |param, val|
      if param.start_with?("_res_paramne_") or (param.start_with?("_res_paramempty_") and val != "")
        myparam = param.sub(/^_res_paramne_/,"").sub(/^_res_paramempty_/,"")
        param_line << "#{myparam}=#{val}"
      end
      if param == "disabled"
        meta_options << 'meta' << 'target-role=Stopped'
      end
      if param == "force" and val
        param_line << "--force"
      end
    }
    return param_line + meta_options
  end
end

get '/remote/?:command?' do
  return remote(params, request, @auth_user)
end

post '/remote/?:command?' do
  return remote(params, request, @auth_user)
end

post '/run_pcs' do
  command = params['command'] || '{}'
  std_in = params['stdin'] || nil
  begin
    command_decoded = JSON.parse(command)
  rescue JSON::ParserError
    result = {
      'status' => 'error',
      'data' => {},
    }
    return JSON.pretty_generate(result)
  end
  # Do not reveal potentially sensitive information: remove --debug and all its
  # prefixes since getopt parser in pcs considers them equal to --debug.
  debug_items = ["--de", "--deb", "--debu", "--debug"]
  command_sanitized = []
  command_decoded.each { |item|
    command_sanitized << item unless debug_items.include?(item)
  }

  allowed_commands = {
    ['cluster', 'auth', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    # runs on the local node, check permissions
    ['cluster', 'corosync'] => {
      'only_superuser' => false,
      'permissions' => Permissions::READ,
    },
    # runs on a remote node which checks permissions by itself
    ['cluster', 'corosync', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    ['cluster', 'destroy', '...'] => {
      'only_superuser' => false,
      'permissions' => Permissions::FULL,
    },
    # runs on the local node, check permissions
    ['cluster', 'disable'] => {
      'only_superuser' => false,
      'permissions' => Permissions::WRITE,
    },
    # runs on a remote node which checks permissions by itself
    ['cluster', 'disable', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    # runs on the local node, check permissions
    ['cluster', 'enable'] => {
      'only_superuser' => false,
      'permissions' => Permissions::WRITE,
    },
    # runs on a remote node which checks permissions by itself
    ['cluster', 'enable', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    ['cluster', 'node', '...'] => {
      'only_superuser' => false,
      'permissions' => Permissions::FULL,
    },
    ['cluster', 'pcsd-status', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    # runs on the local node, check permissions
    ['cluster', 'start'] => {
      'only_superuser' => false,
      'permissions' => Permissions::WRITE,
    },
    # runs on a remote node which checks permissions by itself
    ['cluster', 'start', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    # runs on the local node, check permissions
    ['cluster', 'stop'] => {
      'only_superuser' => false,
      'permissions' => Permissions::WRITE,
    },
    # runs on a remote node which checks permissions by itself
    ['cluster', 'stop', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    ['cluster', 'sync', '...'] => {
      'only_superuser' => false,
      'permissions' => Permissions::FULL,
    },
    ['config', 'restore', '...'] => {
      'only_superuser' => false,
      'permissions' => Permissions::FULL,
    },
    ['host', 'auth', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    ['host', 'deauth', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    ['pcsd', 'deauth', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
    ['pcsd', 'sync-certificates', '...'] => {
      'only_superuser' => false,
      'permissions' => Permissions::FULL,
    },
    ['status', 'pcsd', '...'] => {
      'only_superuser' => false,
      'permissions' => nil,
    },
  }
  allowed = false
  command_settings = {}
  allowed_commands.each { |cmd, cmd_settings|
    if command_sanitized == cmd \
      or \
      (cmd[-1] == '...' and cmd[0..-2] == command_sanitized[0..(cmd.length - 2)])
      then
        allowed = true
        command_settings = cmd_settings
        break
    end
  }
  if !allowed
    result = {
      'status' => 'bad_command',
      'data' => {},
    }
    return JSON.pretty_generate(result)
  end

  if command_settings['only_superuser']
    if not allowed_for_superuser(@auth_user)
      return 403, 'Permission denied'
    end
  end
  if command_settings['permissions']
    if not allowed_for_local_cluster(@auth_user, command_settings['permissions'])
      return 403, 'Permission denied'
    end
  end

  options = {}
  options['stdin'] = std_in if std_in
  std_out, std_err, retval = run_cmd_options(
    @auth_user, options, PCS, *command_sanitized
  )
  result = {
    'status' => 'ok',
    'data' => {
      'stdout' => std_out.join(""),
      'stderr' => std_err.join(""),
      'code' => retval,
    },
  }
  return JSON.pretty_generate(result)
end

get('/login'){ erb :login, :layout => :main }

post '/manage/existingcluster' do
  pcs_config = PCSConfig.new(Cfgsync::PcsdSettings.from_file().text())
  node = params['node-name']
  code, result = send_request_with_token(
    PCSAuth.getSuperuserAuth(), node, 'status'
  )
  begin
    status = JSON.parse(result)
  rescue JSON::ParserError
    return 400, "Unable to communicate with remote pcsd on node '#{node}'."
  end

  if status.has_key?("corosync_offline") and
    status.has_key?("corosync_online") then
    nodes = status["corosync_offline"] + status["corosync_online"]

    if status["cluster_name"] == ''
      return 400, "The node, '#{node}', does not currently have a cluster
 configured.  You must create a cluster using this node before adding it to pcsd."
    end

    if pcs_config.is_cluster_name_in_use(status["cluster_name"])
      return 400, "The cluster name, '#{status['cluster_name']}' has
already been added to pcsd.  You may not add two clusters with the same name into pcsd."
    end

    # auth begin
    new_hosts, warning_messages = pcs_compatibility_layer_get_cluster_known_hosts(
      status['cluster_name'], node
    )
    if not new_hosts.empty?
      pushed, _ = Cfgsync::save_sync_new_known_hosts(
        new_hosts, [], get_corosync_nodes_names(), $cluster_name
      )
      if not pushed
        return 400, "Configuration conflict detected.\n\nSome nodes had a newer configuration than the local node. Local node's configuration was updated.  Please repeat the last action if appropriate."
      end
    end
    #auth end

    pcs_config.clusters << Cluster.new(status["cluster_name"], nodes)

    sync_config = Cfgsync::PcsdSettings.from_text(pcs_config.text())
    pushed, _ = Cfgsync::save_sync_new_version(
      sync_config, get_corosync_nodes_names(), $cluster_name, true
    )
    if not pushed
      return 400, "Configuration conflict detected.\n\nSome nodes had a newer configuration than the local node. Local node's configuration was updated.  Please repeat the last action if appropriate."
    end
    return 200, warning_messages.join("\n\n")
  else
    return 400, "Unable to communicate with remote pcsd on node '#{node}'."
  end
end

post '/manage/newcluster' do
  auth_user = getAuthUser()
  if not allowed_for_superuser(auth_user)
    return 400, 'Permission denied.'
  end

  warning_messages = []

  pcs_config = PCSConfig.new(Cfgsync::PcsdSettings.from_file().text())
  @manage = true
  @cluster_name = params[:clustername]
  @nodes = []
  nodes_with_indexes = []
  @nodes_rrp = []
  options = {}
  params.each {|k,v|
    if k.start_with?("node-") and v != ""
      @nodes << v
      nodes_with_indexes << [k[5..-1].to_i, v]
      if params.has_key?("ring1-" + k) and params["ring1-" + k] != ""
        @nodes_rrp << v + "," + params["ring1-" + k]
      else
        @nodes_rrp << v
      end
    end
    if k.start_with?("config-") and v != ""
      options[k.sub("config-","")] = v
    end
  }
  if pcs_config.is_cluster_name_in_use(@cluster_name)
    return 400, "The cluster name, '#{@cluster_name}' has already been added to pcsd.  You may not add two clusters with the same name into pcsd."
  end

  @nodes.each {|n|
    if pcs_config.is_node_in_use(n)
      return 400, "The node, '#{n}' is already configured in pcsd.  You may not add a node to two different clusters in pcsd."
    end
  }

  # First we need to authenticate future cluster nodes to each other. We use
  # a dirty hack to achieve that. Since the GUI is already authorized (it had
  # to check if the nodes can create a cluster) we will send those GUI tokens
  # to the nodes.
  known_hosts = get_known_hosts().select { |name, obj|
    @nodes.include?(name)
  }
  @nodes.each { |future_node|
    retval = pcs_compatibility_layer_known_hosts_add(
      auth_user, false, future_node, known_hosts
    )
    if retval == 'not_supported'
      warning_messages << "Unable to do correct authentication of cluster on node '#{future_node}', because it is running an old version of pcs/pcsd."
      break
    elsif retval == 'error'
      return 400, "Unable to authenticate all nodes on node '#{future_node}'."
    end
  }

  # the first node from the form is the source of config files
  node_to_send_to = nodes_with_indexes.sort[0][1]
  $logger.info(
    "Sending setup cluster request for: #{@cluster_name} to: #{node_to_send_to}"
  )
  code,out = send_request_with_token(
    auth_user,
    node_to_send_to,
    'setup_cluster',
    true,
    {
      :clustername => @cluster_name,
      :nodes => @nodes_rrp.join(';'),
      :options => options.to_json,
      :encryption => params[:encryption],
    },
    true,
    nil,
    60
  )

  if code == 200
    pushed = false
    2.times {
      # Add the new cluster to config and publish the config.
      # If this host is a node of the cluster, some other node may send its
      # own PcsdSettings.  To handle it we just need to reload the config, as
      # we are waiting for the request to finish, so no locking is needed.
      # If we are in a different cluster we just try twice to update the
      # config, dealing with any updates in between.
      pcs_config = PCSConfig.new(Cfgsync::PcsdSettings.from_file().text())
      pcs_config.clusters << Cluster.new(@cluster_name, @nodes)
      sync_config = Cfgsync::PcsdSettings.from_text(pcs_config.text())
      pushed, _ = Cfgsync::save_sync_new_version(
        sync_config, get_corosync_nodes_names(), $cluster_name, true
      )
      break if pushed
    }
    if not pushed
      return 400, "Configuration conflict detected.\n\nSome nodes had a newer configuration than the local node. Local node's configuration was updated.  Please repeat the last action if appropriate."
    end
  else
    return 400, "Unable to create new cluster. If cluster already exists on one or more of the nodes run 'pcs cluster destroy' on all nodes to remove current cluster configuration.\n\n#{node_to_send_to}: #{out}"
  end

  return warning_messages.join("\n\n")
end

post '/manage/removecluster' do
  pcs_config = PCSConfig.new(Cfgsync::PcsdSettings.from_file().text())
  params.each { |k,v|
    if k.start_with?("clusterid-")
      pcs_config.remove_cluster(k.sub("clusterid-",""))
    end
  }
  sync_config = Cfgsync::PcsdSettings.from_text(pcs_config.text())
  pushed, _ = Cfgsync::save_sync_new_version(
    sync_config, get_corosync_nodes_names(), $cluster_name, true
  )
  if not pushed
    return 400, "Configuration conflict detected.\n\nSome nodes had a newer configuration than the local node.  Local node's configuration was updated.  Please repeat the last action if appropriate."
  end
end

get '/manage/check_auth_against_nodes' do
  auth_user = getAuthUser()
  node_list = []
  if params[:nodes] != nil and params[:nodes] != ''
    node_list = params[:nodes].split(',')
  end
  node_results = {}
  online, offline, notauthorized = is_auth_against_nodes(auth_user, node_list)
  online.each { |node|
    node_results[node] = 'Online'
  }
  offline.each { |node|
    node_results[node] = 'Offline'
  }
  notauthorized.each { |node|
    node_results[node] = 'Unable to authenticate'
  }
  return JSON.generate(node_results)
end

get '/manage/get_nodes_sw_versions' do
  auth_user = getAuthUser()
  if params[:nodes] != nil and params[:nodes] != ''
    nodes = params[:nodes].split(',')
    final_response = {}
    threads = []
    nodes.each {|node|
      threads << Thread.new {
        code, response = send_request_with_token(
          auth_user, node, 'get_sw_versions'
        )
        begin
          node_response = JSON.parse(response)
          if node_response and node_response['notoken'] == true
            $logger.error("ERROR: bad token for #{node}")
          end
          final_response[node] = node_response
        rescue JSON::ParserError
        end
      }
    }
    threads.each { |t| t.join }
    return JSON.generate(final_response)
  end
  return '{}'
end

post '/manage/auth_gui_against_nodes' do
  auth_user = getAuthUser()
  threads = []
  new_hosts = {}
  node_auth_error = {}

  data = JSON.parse(params.fetch('data_json'))
  data.fetch('nodes').each { |node_name, node_data|
    threads << Thread.new {
      dest_list = node_data.fetch('dest_list')
      addr = dest_list.fetch(0).fetch('addr')
      port = dest_list.fetch(0).fetch('port')
      request_data = {
        :username => SUPERUSER,
        :password => node_data.fetch('password'),
      }
      node_auth_error[node_name] = 1
      code, response = send_request(
        auth_user, addr, port, 'auth', true, request_data, true
      )
      if 200 == code
        token = response.strip
        if not token.empty?
          new_hosts[node_name] = PcsKnownHost.new(node_name, token, dest_list)
          node_auth_error[node_name] = 0
        end
      end
    }
  }
  threads.each { |t| t.join }

  if not new_hosts.empty?
    _sync_successful, _sync_responses = Cfgsync::save_sync_new_known_hosts(
      new_hosts.values(), [], get_corosync_nodes_names(), $cluster_name
    )
  end

  return [200, JSON.generate({'node_auth_error' => node_auth_error})]
end

get '/manage/?' do
  @manage = true
  erb :manage, :layout => :main
end

get '/clusters_overview' do
  clusters_overview(params, request, getAuthUser())
end

get '/permissions/?' do
  @manage = true
  pcs_config = PCSConfig.new(Cfgsync::PcsdSettings.from_file().text())
  @clusters = pcs_config.clusters.sort { |a, b| a.name <=> b.name }
  erb :permissions, :layout => :main
end

get '/permissions_cluster_form/:cluster/?' do
  auth_user = getAuthUser()
  @cluster_name = params[:cluster]
  @error = nil
  @permission_types = []
  @permissions_dependencies = {}
  @user_types = []
  @users_permissions = []

  pcs_config = PCSConfig.new(Cfgsync::PcsdSettings.from_file().text())

  if not pcs_config.is_cluster_name_in_use(@cluster_name)
    @error = 'Cluster not found'
  else
    code, data = send_cluster_request_with_token(
      auth_user, @cluster_name, 'get_permissions'
    )
    if 404 == code
      @error = 'Cluster is running an old version of pcsd which does not support permissions'
    elsif 403 == code
      @error = 'Permission denied'
    elsif 200 != code
      @error = 'Unable to load permissions of the cluster'
    else
      begin
        permissions = JSON.parse(data)
        if permissions['notoken'] or permissions['noresponse']
          @error = 'Unable to load permissions of the cluster'
        else
          @permission_types = permissions['permission_types'] || []
          @permissions_dependencies = permissions['permissions_dependencies'] || {}
          @user_types = permissions['user_types'] || []
          @users_permissions = permissions['users_permissions'] || []
        end
      rescue JSON::ParserError
        @error = 'Unable to read permissions of the cluster'
      end
    end
  end
  erb :_permissions_cluster
end

get '/managec/:cluster/main' do
  auth_user = getAuthUser()
  @cluster_name = params[:cluster]
  pcs_config = PCSConfig.new(Cfgsync::PcsdSettings.from_file().text())
  @clusters = pcs_config.clusters
  @nodes = get_cluster_nodes(params[:cluster])
  if @nodes == []
    redirect '/manage/'
  end
  @resource_agent_structures = get_resource_agents_avail(auth_user, params) \
    .map{|agent_name| get_resource_agent_name_structure(agent_name)} \
    .select{|structure| structure != nil}
  @stonith_agents = get_stonith_agents_avail(auth_user, params)
  erb :nodes, :layout => :main
end

post '/managec/:cluster/permissions_save/?' do
  auth_user = getAuthUser()
  new_params = {
    'json_data' => JSON.generate(params)
  }
  return send_cluster_request_with_token(
    auth_user, params[:cluster], "set_permissions", true, new_params
  )
end

get '/managec/:cluster/status_all' do
  auth_user = getAuthUser()
  status_all(params, request, auth_user, get_cluster_nodes(params[:cluster]))
end

get '/managec/:cluster/cluster_status' do
  auth_user = getAuthUser()
  cluster_status_gui(auth_user, params[:cluster])
end

get '/managec/:cluster/cluster_properties' do
  auth_user = getAuthUser()
  cluster = params[:cluster]
  unless cluster
    return 200, {}
  end
  code, out = send_cluster_request_with_token(auth_user, cluster, 'get_cib')
  if code == 403
    return [403, 'Permission denied']
  elsif code != 200
    return [400, 'getting CIB failed']
  end
  begin
    properties = getAllSettings(nil, REXML::Document.new(out))
    code, out = send_cluster_request_with_token(
      auth_user, cluster, 'get_cluster_properties_definition'
    )

    if code == 403
      return [403, 'Permission denied']
    elsif code == 404
      definition = {
        'batch-limit' => {
          'name' => 'batch-limit',
          'source' => 'pacemaker-schedulerd',
          'default' => '0',
          'type' => 'integer',
          'shortdesc' => 'The number of jobs that pacemaker is allowed to execute in parallel.',
          'longdesc' => 'The "correct" value will depend on the speed and load of your network and cluster nodes.',
          'readable_name' => 'Batch Limit',
          'advanced' => false
        },
        'no-quorum-policy' => {
          'name' => 'no-quorum-policy',
          'source' => 'pacemaker-schedulerd',
          'default' => 'stop',
          'type' => 'enum',
          'enum' => ['stop', 'freeze', 'ignore', 'suicide'],
          'shortdesc' => 'What to do when the cluster does not have quorum.',
          'longdesc' => 'Allowed values:
  * ignore - continue all resource management
  * freeze - continue resource management, but don\'t recover resources from nodes not in the affected partition
  * stop - stop all resources in the affected cluster partition
  * suicide - fence all nodes in the affected cluster partition',
          'readable_name' => 'No Quorum Policy',
          'advanced' => false
        },
        'symmetric-cluster' => {
          'name' => 'symmetric-cluster',
          'source' => 'pacemaker-schedulerd',
          'default' => 'true',
          'type' => 'boolean',
          'shortdesc' => 'All resources can run anywhere by default.',
          'longdesc' => 'All resources can run anywhere by default.',
          'readable_name' => 'Symmetric',
          'advanced' => false
        },
        'stonith-enabled' => {
          'name' => 'stonith-enabled',
          'source' => 'pacemaker-schedulerd',
          'default' => 'true',
          'type' => 'boolean',
          'shortdesc' => 'Failed nodes are STONITH\'d',
          'longdesc' => 'Failed nodes are STONITH\'d',
          'readable_name' => 'Stonith Enabled',
          'advanced' => false
        },
        'stonith-action' => {
          'name' => 'stonith-action',
          'source' => 'pacemaker-schedulerd',
          'default' => 'reboot',
          'type' => 'enum',
          'enum' => ['reboot', 'poweroff', 'off'],
          'shortdesc' => 'Action to send to STONITH device',
          'longdesc' => 'Action to send to STONITH device Allowed values: reboot, poweroff, off',
          'readable_name' => 'Stonith Action',
          'advanced' => false
        },
        'cluster-delay' => {
          'name' => 'cluster-delay',
          'source' => 'pacemaker-schedulerd',
          'default' => '60s',
          'type' => 'time',
          'shortdesc' => 'Round trip delay over the network (excluding action execution)',
          'longdesc' => 'The "correct" value will depend on the speed and load of your network and cluster nodes.',
          'readable_name' => 'Cluster Delay',
          'advanced' => false
        },
        'stop-orphan-resources' => {
          'name' => 'stop-orphan-resources',
          'source' => 'pacemaker-schedulerd',
          'default' => 'true',
          'type' => 'boolean',
          'shortdesc' => 'Should deleted resources be stopped',
          'longdesc' => 'Should deleted resources be stopped',
          'readable_name' => 'Stop Orphan Resources',
          'advanced' => false
        },
        'stop-orphan-actions' => {
          'name' => 'stop-orphan-actions',
          'source' => 'pacemaker-schedulerd',
          'default' => 'true',
          'type' => 'boolean',
          'shortdesc' => 'Should deleted actions be cancelled',
          'longdesc' => 'Should deleted actions be cancelled',
          'readable_name' => 'Stop Orphan Actions',
          'advanced' => false
        },
        'start-failure-is-fatal' => {
          'name' => 'start-failure-is-fatal',
          'source' => 'pacemaker-schedulerd',
          'default' => 'true',
          'type' => 'boolean',
          'shortdesc' => 'Always treat start failures as fatal',
          'longdesc' => 'This was the old default. However when set to FALSE, the cluster will instead use the resource\'s failcount and value for resource-failure-stickiness',
          'readable_name' => 'Start Failure is Fatal',
          'advanced' => false
        },
        'pe-error-series-max' => {
          'name' => 'pe-error-series-max',
          'source' => 'pacemaker-schedulerd',
          'default' => '-1',
          'type' => 'integer',
          'shortdesc' => 'The number of PE inputs resulting in ERRORs to save',
          'longdesc' => 'Zero to disable, -1 to store unlimited.',
          'readable_name' => 'PE Error Storage',
          'advanced' => false
        },
        'pe-warn-series-max' => {
          'name' => 'pe-warn-series-max',
          'source' => 'pacemaker-schedulerd',
          'default' => '5000',
          'type' => 'integer',
          'shortdesc' => 'The number of PE inputs resulting in WARNINGs to save',
          'longdesc' => 'Zero to disable, -1 to store unlimited.',
          'readable_name' => 'PE Warning Storage',
          'advanced' => false
        },
        'pe-input-series-max' => {
          'name' => 'pe-input-series-max',
          'source' => 'pacemaker-schedulerd',
          'default' => '4000',
          'type' => 'integer',
          'shortdesc' => 'The number of other PE inputs to save',
          'longdesc' => 'Zero to disable, -1 to store unlimited.',
          'readable_name' => 'PE Input Storage',
          'advanced' => false
        },
        'enable-acl' => {
          'name' => 'enable-acl',
          'source' => 'pacemaker-based',
          'default' => 'false',
          'type' => 'boolean',
          'shortdesc' => 'Enable CIB ACL',
          'longdesc' => 'Should pacemaker use ACLs to determine access to cluster',
          'readable_name' => 'Enable ACLs',
          'advanced' => false
        },
      }
    elsif code != 200
      return [400, 'getting properties definition failed']
    else
      definition = JSON.parse(out)
    end

    definition.each { |name, prop|
      prop['value'] = properties[name]
    }
    return [200, JSON.generate(definition)]
  rescue
    return [400, 'unable to get cluster properties']
  end
end

get '/managec/:cluster/get_resource_agent_metadata' do
  auth_user = getAuthUser()
  cluster = params[:cluster]
  resource_agent = params[:agent]
  code, out = send_cluster_request_with_token(
    auth_user,
    cluster,
    'get_resource_agent_metadata',
    false,
    {:resource_agent => resource_agent}
  )
  if code != 404
    return [code, out]
  end

  code, out = send_cluster_request_with_token(
    auth_user,
    cluster,
    'resource_metadata',
    false,
    {
      :resourcename => resource_agent,
      :new => true
    }
  )
  if code != 200
    return [400, 'Unable to get meta-data of specified resource agent.']
  end
  desc_regex = Regexp.new(
    '<span class="reg[^>]*>(?<short>[^>]*)&nbsp;</span>[^<]*' +
      '<span title="(?<long>[^"]*)"'
  )
  parameters_regex = Regexp.new(
    '<input type="hidden" name="resource_type"[^>]*>(?<required>[\s\S]*)' +
      '<div class="bold">Optional Arguments:</div>(?<optional>[\S\s]*)' +
      '<tr class="stop">'
  )
  parameter_regex = Regexp.new(
    '<tr title="(?<longdesc>[^"]*)"[^>]*>[\s]*<td class="reg">\s*' +
      '(?<name>[^<\s]*)\s*</td>\s*<td>\s*' +
      '<input placeholder="(?<shortdesc>[^"]*)"'
  )

  desc = desc_regex.match(out)
  unless desc
    return [400, 'Unable to get meta-data of specified resource agent.']
  end
  result = {
    :name => resource_agent,
    :shortdesc => html2plain(desc[:short]),
    :longdesc => html2plain(desc[:long]),
    :parameters => []
  }

  parameters = parameters_regex.match(out)
  parameters[:required].scan(parameter_regex) { |match|
    result[:parameters] << {
      :name => html2plain(match[1]),
      :longdesc => html2plain(match[0]),
      :shortdesc => html2plain(match[2]),
      :type => 'string',
      :required => true
    }
  }
  parameters[:optional].scan(parameter_regex) { |match|
    result[:parameters] << {
      :name => html2plain(match[1]),
      :longdesc => html2plain(match[0]),
      :shortdesc => html2plain(match[2]),
      :type => 'string',
      :required => false
    }
  }
  return [200, JSON.generate(result)]
end

get '/managec/:cluster/get_fence_agent_metadata' do
  auth_user = getAuthUser()
  cluster = params[:cluster]
  fence_agent = params[:agent]
  code, out = send_cluster_request_with_token(
    auth_user,
    cluster,
    'get_fence_agent_metadata',
    false,
    {:fence_agent => fence_agent}
  )
  if code != 404
    return [code, out]
  end

  code, out = send_cluster_request_with_token(
    auth_user,
    cluster,
    'fence_device_metadata',
    false,
    {
      :resourcename => fence_agent.sub('stonith:', ''),
      :new => true
    }
  )
  if code != 200
    return [400, 'Unable to get meta-data of specified fence agent.']
  end
  desc_regex = Regexp.new(
    '<span class="reg[^>]*>(?<short>[^>]*)&nbsp;</span>[^<]*' +
      '<span title="(?<long>[^"]*)"'
  )
  parameters_regex = Regexp.new(
    '<input type="hidden" name="resource_type"[^>]*>(?<required>[\s\S]*)' +
      '<div class="bold">Optional Arguments:</div>(?<optional>[\S\s]*)' +
      '<div class="bold">Advanced Arguments:</div>(?<advanced>[\S\s]*)' +
      '<tr class="stop">'
  )
  required_parameter_regex = Regexp.new(
    '<tr title="(?<longdesc>[^"]*)[^>]*>[\s]*' +
      '<td class="reg">\s*&nbsp;(?<name>[^<\s]*)\s*</td>\s*<td>\s*' +
      '<input placeholder="(?<shortdesc>[^"]*)"'
  )
  other_parameter_regex = Regexp.new(
    '<td class="reg">\s*&nbsp;(?<name>[^<\s]*)\s*</td>\s*<td>\s*' +
      '<input placeholder="(?<shortdesc>[^"]*)"'
  )

  result = {
    :name => fence_agent,
    :shortdesc => '',
    :longdesc => '',
    :parameters => []
  }

  # pcsd in version 0.9.137 (and older) does not provide description for
  # fence agents
  desc = desc_regex.match(out)
  if desc
    result[:shortdesc] = html2plain(desc[:short])
    result[:longdesc] = html2plain(desc[:long])
  end

  parameters = parameters_regex.match(out)
  parameters[:required].scan(required_parameter_regex) { |match|
    result[:parameters] << {
      :name => html2plain(match[1]),
      :longdesc => html2plain(match[0]),
      :shortdesc => html2plain(match[2]),
      :type => 'string',
      :required => true,
      :advanced => false
    }
  }
  parameters[:optional].scan(other_parameter_regex) { |match|
    result[:parameters] << {
      :name => html2plain(match[0]),
      :longdesc => '',
      :shortdesc => html2plain(match[1]),
      :type => 'string',
      :required => false,
      :advanced => false
    }
  }
  parameters[:advanced].scan(other_parameter_regex) { |match|
    result[:parameters] << {
      :name => html2plain(match[0]),
      :longdesc => '',
      :shortdesc => html2plain(match[1]),
      :type => 'string',
      :required => false,
      :advanced => true
    }
  }
  return [200, JSON.generate(result)]
end

post '/managec/:cluster/fix_auth_of_cluster' do
  clustername = params[:cluster]
  unless clustername
    return [400, "cluster name not defined"]
  end

  nodes = get_cluster_nodes(clustername)
  known_hosts = get_known_hosts().select { |name, obj|
    nodes.include?(name)
  }
  retval = pcs_compatibility_layer_known_hosts_add(
    PCSAuth.getSuperuserAuth(), true, clustername, known_hosts
  )
  if retval == 'not_supported'
    return [400, "Old version of PCS/PCSD is running on cluster nodes. Fixing authentication is not supported. Use 'pcs cluster auth' command to authenticate the nodes."]
  elsif retval == 'error'
    return [400, "Authentication failed."]
  end
  return [200, "Auhentication of nodes in cluster should be fixed."]
end

post '/managec/:cluster/add_node_to_cluster' do
  auth_user = getAuthUser()
  clustername = params[:cluster]
  new_node = params["new_nodename"]

  if clustername == $cluster_name
    if not allowed_for_local_cluster(auth_user, Permissions::FULL)
      return 403, 'Permission denied'
    end
  end

  known_hosts = get_known_hosts()
  if not known_hosts.include? new_node
    return [400, "New node is not authenticated."]
  end

  # Save the new node token on all nodes in a cluster the new node is beeing
  # added to. Send the token to one node and let the cluster nodes synchronize
  # it by themselves.
  new_node_known_hosts = {new_node => known_hosts[new_node]}
  retval = pcs_compatibility_layer_known_hosts_add(
    # new node doesn't have config with permissions yet
    PCSAuth.getSuperuserAuth(), true, clustername, new_node_known_hosts
  )
  # If the cluster runs an old pcsd which doesn't support adding known hosts,
  # ignore 404 in order to not prevent the node to be added.
  if retval != 'not_supported' and retval != 'success'
    return [400, 'Failed to save the token of the new node in the target cluster.']
  end

  retval, out = send_cluster_request_with_token(
    auth_user, clustername, "/add_node_all", true, params
  )
  if 403 == retval
    return [retval, out]
  end
  if retval != 200
    return [400, "Failed to add new node '#{new_node}' into cluster '#{clustername}': #{out}"]
  end

  return [200, "Node added successfully."]
end

def pcs_compatibility_layer_known_hosts_add(
  auth_user, is_cluster_request, target, known_hosts
)
  # try the new endpoint provided by pcs-0.10
  known_hosts_request_data = {}
  known_hosts.each { |host_name, host_obj|
    known_hosts_request_data[host_name] = {
      'dest_list' => host_obj.dest_list,
      'token' => host_obj.token,
    }
  }
  request_data = {
    'data_json' => JSON.generate(
      {
        'known_hosts_add' => known_hosts_request_data,
        'known_hosts_remove' => [],
      }
    ),
  }
  if is_cluster_request
    retval, _out = send_cluster_request_with_token(
      auth_user, target, '/known_hosts_change', true, request_data
    )
  else
    retval, _out = send_request_with_token(
      auth_user, target, '/known_hosts_change', true, request_data
    )
  end

  # a remote host supports the endpoint; success
  if retval == 200
    return 'success'
  end

  # a remote host supports the endpoint; error
  if retval != 404
    return 'error'
  end

  # a remote host does not support the endpoint
  # fallback to the old endpoint provided by pcs-0.9 since 0.9.140
  request_data = {}
  known_hosts.each { |host_name, host_obj|
    addr = host_obj.first_dest()['addr']
    port = host_obj.first_dest()['port']
    request_data["node:#{host_name}"] = host_obj.token
    request_data["port:#{host_name}"] = port
    request_data["node:#{addr}"] = host_obj.token
    request_data["port:#{addr}"] = port
  }
  if is_cluster_request
    retval, _out = send_cluster_request_with_token(
      auth_user, target, '/save_tokens', true, request_data
    )
  else
    retval, _out = send_request_with_token(
      auth_user, target, '/save_tokens', true, request_data
    )
  end

  # a remote host supports the endpoint; success
  if retval == 200
    return 'success'
  end

  # a remote host supports the endpoint; error
  if retval != 404
    return 'error'
  end

  # a remote host does not support any of the endpoints
  # there's nothing we can do about it
  return 'not_supported'
end

def pcs_compatibility_layer_get_cluster_known_hosts(cluster_name, target_node)
  warning_messages = []
  known_hosts = []
  auth_user = PCSAuth.getSuperuserAuth()

  # try the new endpoint provided by pcs-0.10
  retval, out = send_request_with_token(
    auth_user, target_node, '/get_cluster_known_hosts'
  )
  # a remote host supports /get_cluster_known_hosts; data downloaded
  if retval == 200
    begin
      JSON.parse(out).each { |name, data|
        known_hosts << PcsKnownHost.new(
          name,
          data.fetch('token'),
          data.fetch('dest_list')
        )
      }
    rescue => e
      $logger.error "Unable to parse the response of /get_cluster_known_hosts: #{e}"
      known_hosts = []
      warning_messages << (
        "Unable to automatically authenticate against cluster nodes: " +
        "cannot get authentication info from cluster '#{cluster_name}'"
      )
    end
    return known_hosts, warning_messages
  end

  # a remote host supports /get_cluster_known_hosts; an error occured
  if retval != 404
    warning_messages << (
      "Unable to automatically authenticate against cluster nodes: " +
      "cannot get authentication info from cluster '#{cluster_name}'"
    )
    return known_hosts, warning_messages
  end

  # a remote host does not support /get_cluster_known_hosts
  # fallback to the old endpoint provided by pcs-0.9 since 0.9.140
  retval, out = send_request_with_token(
    auth_user, target_node, '/get_cluster_tokens', false, {'with_ports' => '1'}
  )

  # a remote host supports /get_cluster_tokens; data downloaded
  if retval == 200
    begin
      data = JSON.parse(out)
      expected_keys = ['tokens', 'ports']
      if expected_keys.all? {|i| data.has_key?(i) and data[i].class == Hash}
        # new format
        new_tokens = data["tokens"] || {}
        new_ports = data["ports"] || {}
      else
        # old format
        new_tokens = data
        new_ports = {}
      end
      new_tokens.each { |name_addr, token|
        known_hosts << PcsKnownHost.new(
          name_addr,
          token,
          [
            {
              'addr' => name_addr,
              'port' => (new_ports[name_addr] || PCSD_DEFAULT_PORT),
            }
          ]
        )
      }
    rescue => e
      $logger.error "Unable to parse the response of /get_cluster_tokens: #{e}"
      known_hosts = []
      warning_messages << (
        "Unable to automatically authenticate against cluster nodes: " +
        "cannot get authentication info from cluster '#{cluster_name}'"
      )
    end
    return known_hosts, warning_messages
  end

  # a remote host supports /get_cluster_tokens; an error occured
  if retval != 404
    warning_messages << (
      "Unable to automatically authenticate against cluster nodes: " +
      "cannot get authentication info from cluster '#{cluster_name}'"
    )
    return known_hosts, warning_messages
  end

  # a remote host does not support /get_cluster_tokens
  # there's nothing we can do about it
  warning_messages << (
    "Unable to automatically authenticate against cluster nodes: " +
    "cluster '#{cluster_name}' is running an old version of pcs/pcsd"
  )
  return known_hosts, warning_messages
end

def pcs_0_9_142_resource_change_group(auth_user, params)
  parameters = {
    :resource_id => params[:resource_id],
    :resource_group => '',
    :_orig_resource_group => '',
  }
  parameters[:resource_group] = params[:group_id] if params[:group_id]
  if params[:old_group_id]
    parameters[:_orig_resource_group] = params[:old_group_id]
  end
  return send_cluster_request_with_token(
    auth_user, params[:cluster], 'update_resource', true, parameters
  )
end

def pcs_0_9_142_resource_clone(auth_user, params)
  parameters = {
    :resource_id => params[:resource_id],
    :resource_clone => true,
    :_orig_resource_clone => 'false',
  }
  return send_cluster_request_with_token(
    auth_user, params[:cluster], 'update_resource', true, parameters
  )
end

def pcs_0_9_142_resource_unclone(auth_user, params)
  parameters = {
    :resource_id => params[:resource_id],
    :resource_clone => nil,
    :_orig_resource_clone => 'true',
  }
  return send_cluster_request_with_token(
    auth_user, params[:cluster], 'update_resource', true, parameters
  )
end

def pcs_0_9_142_resource_master(auth_user, params)
  parameters = {
    :resource_id => params[:resource_id],
    :resource_ms => true,
    :_orig_resource_ms => 'false',
  }
  return send_cluster_request_with_token(
    auth_user, params[:cluster], 'update_resource', true, parameters
  )
end

# There is a bug in pcs-0.9.138 and older in processing the standby and
# unstandby request. JS of that pcsd always sent nodename in "node"
# parameter, which caused pcsd daemon to run the standby command locally with
# param["node"] as node name. This worked fine if the local cluster was
# managed from JS, as pacemaker simply put the requested node into standby.
# However it didn't work for managing non-local clusters, as the command was
# run on the local cluster everytime. Pcsd daemon would send the request to a
# remote cluster if the param["name"] variable was set, and that never
# happened. That however wouldn't work either, as then the required parameter
# "node" wasn't sent in the request causing an exception on the receiving
# node. This is fixed in commit 053f63ca109d9ef9e7f0416e90aab8e140480f5b
#
# In order to be able to put nodes running pcs-0.9.138 into standby, the
# nodename must be sent in "node" param, and the "name" must not be sent.
def pcs_0_9_138_node_standby(auth_user, params)
  translated_params = {
    'node' => params[:name],
  }
  return send_cluster_request_with_token(
    auth_user, params[:cluster], 'node_standby', true, translated_params
  )
end

def pcs_0_9_138_node_unstandby(auth_user, params)
  translated_params = {
    'node' => params[:name],
  }
  return send_cluster_request_with_token(
    auth_user, params[:cluster], 'node_unstandby', true, translated_params
  )
end

post '/managec/:cluster/?*' do
  auth_user = getAuthUser()
  raw_data = request.env["rack.input"].read
  if params[:cluster]
    request = "/" + params[:splat].join("/")

    # backward compatibility layer BEGIN
    translate_for_version = {
      '/node_standby' => [
        [[0, 9, 138], method(:pcs_0_9_138_node_standby)],
      ],
      '/node_unstandby' => [
        [[0, 9, 138], method(:pcs_0_9_138_node_unstandby)],
      ],
    }
    if translate_for_version.key?(request)
      target_pcsd_version = [0, 0, 0]
      version_code, version_out = send_cluster_request_with_token(
        auth_user, params[:cluster], 'get_sw_versions'
      )
      if version_code == 200
        begin
          versions = JSON.parse(version_out)
          target_pcsd_version = versions['pcs'] if versions['pcs']
        rescue JSON::ParserError
        end
      end
      translate_function = nil
      translate_for_version[request].each { |pair|
        if (target_pcsd_version <=> pair[0]) != 1 # target <= pair
          translate_function = pair[1]
          break
        end
      }
    end
    # backward compatibility layer END

    if translate_function
      code, out = translate_function.call(auth_user, params)
    else
      code, out = send_cluster_request_with_token(
        auth_user, params[:cluster], request, true, params, true, raw_data
      )
    end

    # backward compatibility layer BEGIN
    if code == 404
      case request
        # supported since pcs-0.9.143 (tree view of resources)
        when '/resource_change_group'
          code, out =  pcs_0_9_142_resource_change_group(auth_user, params)
        # supported since pcs-0.9.143 (tree view of resources)
        when '/resource_clone'
          code, out = pcs_0_9_142_resource_clone(auth_user, params)
        # supported since pcs-0.9.143 (tree view of resources)
        when '/resource_unclone'
          code, out = pcs_0_9_142_resource_unclone(auth_user, params)
        # supported since pcs-0.9.143 (tree view of resources)
        when '/resource_master'
          code, out = pcs_0_9_142_resource_master(auth_user, params)
        else
          redirection = {
            # constraints removal for pcs-0.9.137 and older
            "/remove_constraint_remote" => "/resource_cmd/rm_constraint",
            # constraints removal for pcs-0.9.137 and older
            "/remove_constraint_rule_remote" => "/resource_cmd/rm_constraint_rule"
          }
          if redirection.key?(request)
            code, out = send_cluster_request_with_token(
              auth_user,
              params[:cluster],
              redirection[request],
              true,
              params,
              false,
              raw_data
            )
          end
      end
    end
    # backward compatibility layer END

    return code, out
  end
end

get '/managec/:cluster/?*' do
  auth_user = getAuthUser()
  raw_data = request.env["rack.input"].read
  if params[:cluster]
    send_cluster_request_with_token(
      auth_user,
      params[:cluster],
      "/" + params[:splat].join("/"),
      false,
      params,
      true,
      raw_data
    )
  end
end

get '/' do
  $logger.info "Redirecting '/'...\n"
  redirect '/manage'
end

get '*' do
  $logger.debug "Bad URL"
  $logger.debug params[:splat]
  $logger.info "Redirecting '*'...\n"
  redirect '/manage'
  redirect "Bad URL"
  call(env.merge("PATH_INFO" => '/nodes'))
end

class Node
  attr_accessor :active, :id, :name, :hostname

  def initialize(id=nil, name=nil, hostname=nil, active=nil)
    @id, @name, @hostname, @active = id, name, hostname, active
  end
end

def html2plain(text)
  return CGI.unescapeHTML(text).gsub(/<br[^>]*>/, "\n")
end

helpers do
  def h(text)
    Rack::Utils.escape_html(text)
  end

  def nl2br(text)
    text.gsub(/\n/, "<br>")
  end
end
