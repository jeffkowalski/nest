#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'yaml'
require 'rest-client'
require 'json'
require 'influxdb'

LOGFILE = File.join(Dir.home, '.log', 'nest.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'nest.yaml')

class Nest < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new STDOUT
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'
  class_option :dry_run, type: :boolean, aliases: '-d', desc: 'do not write to database'

  desc 'authorize', '[re]authorize the application'
  def authorize
    credentials = YAML.load_file CREDENTIALS_PATH
    state = Time.now.to_i
    puts "Go to this URL https://home.nest.com/login/oauth2?client_id=#{credentials[:client_id]}&state=#{state}"
    puts 'Copy PIN and paste it here:'
    pin = $stdin.gets.chomp
    response = RestClient.post('https://api.home.nest.com/oauth2/access_token',
                               code: pin,
                               client_id: credentials[:client_id],
                               client_secret: credentials[:client_secret],
                               grant_type: 'authorization_code')
    token = JSON.parse(response)
    credentials[:access_token] = token['access_token']
    File.open(CREDENTIALS_PATH, 'w') { |file| file.write(credentials.to_yaml) }
  end

  desc 'record-status', 'record the current usage data to database'
  def record_status
    setup_logger
    begin
      credentials = YAML.load_file CREDENTIALS_PATH

      response = RestClient::Request.execute(
        method: 'get',
        url: 'https://developer-api.nest.com/devices/thermostats',
        headers: { authorization: "Bearer #{credentials[:access_token]}",
                   content_type: 'application/json' }
      )
      thermostats = JSON.parse response
      @logger.info thermostats

      influxdb = InfluxDB::Client.new 'nest'

      thermostats.values.each do |ts|
        @logger.debug ts
        # ambient_temperature_f => 73
        # hvac_state => "heating", "cooling", "off"
        # last_connection => "2018-10-15T03:53:54.097Z"

        timestamp = Time.parse(ts['last_connection']).to_i

        unless ts['fan_timer_active'].nil?
          data = {
            values: { value: ts['fan_timer_active'] },
            tags: { name_long: ts['name_long'] },
            timestamp: timestamp
          }
          influxdb.write_point('fan_timer_active', data) unless options[:dry_run]
        end

        unless ts['hvac_mode'].nil?
          data = {
            values: { value: ts['hvac_mode'] },
            tags: { name_long: ts['name_long'] },
            timestamp: timestamp
          }
          influxdb.write_point('hvac_mode', data) unless options[:dry_run]
        end

        unless ts['hvac_state'].nil?
          data = {
            values: { value: ts['hvac_state'] },
            tags: { name_long: ts['name_long'] },
            timestamp: timestamp
          }
          influxdb.write_point('hvac_state', data) unless options[:dry_run]
        end

        unless ts['ambient_temperature_f'].nil?
          data = {
            values: { value: ts['ambient_temperature_f'].to_f },
            tags: { name_long: ts['name_long'] },
            timestamp: timestamp
          }
          influxdb.write_point('ambient_temperature_f', data) unless options[:dry_run]
        end

        unless ts['target_temperature_f'].nil?
          data = {
            values: { value: ts['target_temperature_f'].to_f },
            tags: { name_long: ts['name_long'] },
            timestamp: timestamp
          }
          influxdb.write_point('target_temperature_f', data) unless options[:dry_run]
        end

        unless ts['humidity'].nil?
          data = {
            values: { value: ts['humidity'].to_i },
            tags: { name_long: ts['name_long'] },
            timestamp: timestamp
          }
          influxdb.write_point('humidity', data) unless options[:dry_run]
        end
      end
    rescue StandardError => e
      @logger.error e
    end
  end
end

Nest.start
