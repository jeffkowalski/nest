#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

class Nest < RecorderBotBase
  desc 'authorize', '[re]authorize the application'
  def authorize
    credentials = load_credentials
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
    store_credentials credentials
  end

  no_commands do
    def main
      credentials = load_credentials

      response = with_rescue([RestClient::Exceptions::OpenTimeout], @logger) do |_try|
        RestClient::Request.execute(
          method: 'get',
          url: 'https://developer-api.nest.com/devices/thermostats',
          headers: { authorization: "Bearer #{credentials[:access_token]}",
                     content_type: 'application/json' }
        )
      end
      thermostats = JSON.parse response
      @logger.info thermostats

      influxdb = InfluxDB::Client.new 'nest' unless options[:dry_run]

      transforms = {
        'fan_timer_active'      => ->(v) { v.to_s },
        'hvac_mode'             => ->(v) { v.to_s },
        'hvac_state'            => ->(v) { v.to_s },
        'ambient_temperature_f' => ->(v) { v.to_f },
        'target_temperature_f'  => ->(v) { v.to_f },
        'humidity'              => ->(v) { v.to_i }
      }

      data = []
      thermostats.each_value do |ts|
        @logger.debug ts
        # ambient_temperature_f => 73
        # hvac_state => "heating", "cooling", "off"
        # last_connection => "2018-10-15T03:53:54.097Z"

        timestamp = Time.parse(ts['last_connection']).to_i

        transforms.each do |measure, transform|
          next if ts[measure].nil?

          data.push({ series: measure,
                      values: { value: transform.call(ts[measure]) },
                      tags: { name_long: ts['name_long'] },
                      timestamp: timestamp })
        end
      end
      influxdb.write_points data unless options[:dry_run]
    end
  end
end

Nest.start
