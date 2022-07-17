#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

class Float
  def c_to_f
    9.0 * self / 5.0 + 32.0
  end
end

class Nest < RecorderBotBase
  BASE_NEST_URL = 'https://smartdevicemanagement.googleapis.com/v1/'

  no_commands do
    def refresh_access_token
      credentials = load_credentials

      response = RestClient.post('https://oauth2.googleapis.com/token',
                                 client_id:     credentials[:client_id],
                                 client_secret: credentials[:client_secret],
                                 refresh_token: credentials[:refresh_token],
                                 grant_type:    'refresh_token')
      token = JSON.parse(response)
      credentials[:access_token] = token['access_token']
      store_credentials credentials
    end

    def main
      refresh_access_token
      credentials = load_credentials

      influxdb = InfluxDB::Client.new 'nest' unless options[:dry_run]
      data = []

      url = BASE_NEST_URL + "enterprises/#{credentials[:project_id]}/devices"
      response = RestClient.get(url, content_type: 'application/json', authorization: "Bearer #{credentials[:access_token]}")
      devices = JSON.parse(response)['devices']
      timestamp = DateTime.parse(response.headers[:date]).to_time.to_i

      devices.select { |dev| dev['type'] == 'sdm.devices.types.THERMOSTAT' }.each do |ts|
        @logger.debug ts.pretty_inspect

        traits = ts['traits']
        name_long = traits['sdm.devices.traits.Info']['customName']
        name_long = ts['parentRelations'][0]['displayName'] if name_long.empty?
        measures = {
          fan_timer_active:      traits['sdm.devices.traits.Fan']['timerMode']&.downcase == 'on',
          hvac_mode:             traits['sdm.devices.traits.ThermostatEco']['mode'] == 'MANUAL_ECO' ? 'eco' : traits['sdm.devices.traits.ThermostatMode']['mode']&.downcase,
          hvac_state:            traits['sdm.devices.traits.ThermostatHvac']['status']&.downcase,
          ambient_temperature_f: traits['sdm.devices.traits.Temperature']['ambientTemperatureCelsius'].to_f.c_to_f,
          humidity:              traits['sdm.devices.traits.Humidity']['ambientHumidityPercent'].to_i
        }
        if measures[:hvac_mode].include? 'heat'
          measures[:target_temperature_f] = traits['sdm.devices.traits.ThermostatTemperatureSetpoint']['heatCelsius'].to_f.c_to_f
        elsif measures[:hvac_mode].include? 'cool'
          measures[:target_temperature_f] = traits['sdm.devices.traits.ThermostatTemperatureSetpoint']['coolCelsius'].to_f.c_to_f
        end
        measures.each do |measure, value|
          data.push({ series: measure.to_s,
                      values: { value: value },
                      tags: { name_long: name_long },
                      timestamp: timestamp })
        end
      end

      @logger.debug data.pretty_inspect
      influxdb.write_points data unless options[:dry_run]
    end
  end
end

Nest.start
