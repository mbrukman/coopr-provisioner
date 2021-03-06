#!/usr/bin/env ruby
# encoding: UTF-8
#
# Copyright © 2012-2015 Cask Data, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'base64'
require 'fileutils'

# Docker Automator class
class DockerAutomator < Automator
  # plugin defined resources
  @ssh_key_dir = 'ssh_keys'
  class << self
    attr_accessor :ssh_key_dir
  end

  def write_ssh_file
    @ssh_keyfile = @task['config']['provider']['provisioner']['ssh_keyfile']
    unless @ssh_keyfile.nil?
      @task['config']['ssh-auth']['identityfile'] = File.join(Dir.pwd, self.class.ssh_key_dir, @task['taskId'])
      @ssh_file = @task['config']['ssh-auth']['identityfile']
      log.debug "Writing out @ssh_keyfile to #{@task['config']['ssh-auth']['identityfile']}"
      decode_string_to_file(@ssh_keyfile, @task['config']['ssh-auth']['identityfile'])
    end
    credentials(@sshauth)
  end

  def credentials(sshauth)
    @credentials = {}
    @credentials[:paranoid] = false
    sshauth.each do |k, v|
      if k =~ /identityfile/
        @credentials[:keys] = [v]
      elsif k =~ /password/
        @credentials[:password] = v
      end
    end
  end

  def decode_string_to_file(string, outfile, mode = 0600)
    FileUtils.mkdir_p(File.dirname(outfile))
    File.open(outfile, 'wb', mode) { |f| f.write(Base64.decode64(string)) }
  end

  def docker_command(cmd)
    # do we need sudo bash?
    sudo = 'sudo' unless @sshuser == 'root'
    Net::SSH.start(@ipaddress, @sshuser, @credentials) do |ssh|
      ssh_exec!(ssh, "#{sudo} docker #{cmd}", "Running: docker #{cmd}")
    end
  rescue CommandExecutionError
    raise $!, "Docker command failed on #{@ipaddress}: docker #{cmd}"
  rescue Net::SSH::AuthenticationFailed
    raise $!, "SSH Authentication failure for #{@ipaddress}: #{$!}", $!.backtrace
  end

  def search_image(image_name)
    search = docker_command("search #{image_name} | tail -n +2 | awk '{print $1}'")[0].split(/\r?\n/)
    case search.count
    when 1
      return true
    when 0
      fail "Image #{image_name} not found!"
    else
      fail "More than one image found for #{image_name}!"
    end
  end

  def pull_image(image_name)
    docker_command("pull #{image_name}")
  end

  def portmap
    portmap = ''
    ports = @task['config']['ports'] ? @task['config']['ports'] : []
    # TODO: check for port conflicts and error
    @fields['publish_ports'].split(',').each do |port|
      portmap = "#{portmap}-p #{port}:#{port} " # extra space at end
      if !ports.nil? && ports.include?(port)
        fail "Port #{port} already in use on this host!"
      else
        ports += [port]
      end
    end
    @ports = ports
    portmap
  end

  def run_container(image_name)
    # TODO: make this smarter (run vs start, etc)
    docker_command("run -d #{portmap} #{image_name}")
  end

  def start_container(id)
    docker_command("start #{id}")
  end

  def stop_container(id)
    docker_command("stop #{id}")
  end

  def remove_container(id)
    docker_command("rm #{id}")
  end

  def parse_inputmap(inputmap)
    @sshauth = inputmap['sshauth']
    @sshuser = inputmap['sshauth']['user']
    @ipaddress = inputmap['ipaddress']
    @fields = inputmap['fields']
    @image_name = @fields && @fields.key?('image_name') ? @fields['image_name'].gsub(/\s+/, '') : nil
  end

  # bootstrap remote machine: check for docker
  def bootstrap(inputmap)
    log.debug "DockerAutomator performing bootstrap task #{@task['taskId']}"
    parse_inputmap(inputmap)
    write_ssh_file

    log.debug "Attempting ssh into ip: #{@ipaddress}, user: #{@sshuser}"
    begin
      Net::SSH.start(@ipaddress, @sshuser, @credentials) do |ssh|
        ssh_exec!(ssh, 'which docker', 'Check for docker binary')
      end
    rescue Net::SSH::AuthenticationFailed
      raise $!, "SSH Authentication failure for #{@ipaddress}: #{$!}", $!.backtrace
    end

    @result['status'] = 0
    log.debug "DockerAutomator bootstrap completed successfully: #{@result}"
    @result
  ensure
    File.delete(@ssh_file) if @ssh_file && File.exist?(@ssh_file)
  end

  def install(inputmap)
    log.debug "DockerAutomator performing install task #{@task['taskId']}"
    parse_inputmap(inputmap)
    write_ssh_file
    log.debug "Attempting ssh into ip: #{@ipaddress}, user: #{@sshuser}"
    pull_image(@image_name) if search_image(@image_name)
    @result['status'] = 0
    log.debug "DockerAutomator install completed successfully: #{@result}"
    @result
  ensure
    File.delete(@ssh_file) if @ssh_file && File.exist?(@ssh_file)
  end

  def configure(*)
    log.debug "Docker doesn't really have a configure step"
    @result['status'] = 0
  end

  def init(*)
    log.debug "Docker doesn't really have an initialize step"
    @result['status'] = 0
  end

  def start(inputmap)
    log.debug "DockerAutomator performing start task #{@task['taskId']}"
    parse_inputmap(inputmap)
    write_ssh_file
    log.debug "Attempting ssh into ip: #{@ipaddress}, user: #{@sshuser}"
    @result['result'][@image_name]['id'] = run_container(@image_name)[0].chomp
    @result['result']['ports'] = @ports
    @result['status'] = 0
    log.debug "DockerAutomator start completed successfully: #{@result}"
    @result
  ensure
    File.delete(@ssh_file) if @ssh_file && File.exist?(@ssh_file)
  end

  def stop(inputmap)
    log.debug "DockerAutomator performing stop task #{@task['taskId']}"
    parse_inputmap(inputmap)
    write_ssh_file
    log.debug "Attempting ssh into ip: #{@ipaddress}, user: #{@sshuser}"
    stop_container(@task['config'][@image_name]['id'])
    @result['result']['ports'] = nil
    @result['status'] = 0
    log.debug "DockerAutomator stop completed successfully: #{@result}"
    @result
  ensure
    File.delete(@ssh_file) if @ssh_file && File.exist?(@ssh_file)
  end

  def remove(inputmap)
    log.debug "DockerAutomator performing remove task #{@task['taskId']}"
    parse_inputmap(inputmap)
    write_ssh_file
    log.debug "Attempting ssh into ip: #{@ipaddress}, user: #{@sshuser}"
    remove_container(@task['config'][@image_name]['id'])
    @task['config'][@image_name] = {}
    @result['status'] = 0
    log.debug "DockerAutomator remove completed successfully: #{@result}"
    @result
  ensure
    File.delete(@ssh_file) if @ssh_file && File.exist?(@ssh_file)
  end
end
