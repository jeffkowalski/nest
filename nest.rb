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
  no_commands {
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), :mode => 0755)
        FileUtils.touch logfile
        File.chmod 0644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      $logger = Logger.new STDOUT
      $logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      $logger.info 'starting'
    end
  }

  class_option :log,     :type => :boolean, :default => true, :desc => "log output to ~/.rainforest.log"
  class_option :verbose, :type => :boolean, :aliases => "-v", :desc => "increase verbosity"


  desc "authorize", "[re]authorize the application"
  def authorize
    credentials = YAML.load_file CREDENTIALS_PATH
    state = Time::now.to_i
    puts "Go to this URL https://home.nest.com/login/oauth2?client_id=#{credentials[:client_id]}&state=#{state}"
    puts "Copy PIN and paste it here:"
    pin = $stdin.gets.chomp
    response = RestClient.post("https://api.home.nest.com/oauth2/access_token",
                               {code: pin, client_id: credentials[:client_id], client_secret: credentials[:client_secret], grant_type: 'authorization_code'})
    token = JSON.parse(response)
    credentials[:access_token] = token['access_token']
    File.open(CREDENTIALS_PATH, "w") { |file| file.write(credentials.to_yaml) }
  end


  desc "record-status", "record the current usage data to database"
  def record_status
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH

    response = RestClient::Request.execute(
      method: 'get',
      url: "https://developer-api.nest.com/devices/thermostats",
      headers: {authorization: "Bearer #{credentials[:access_token]}",
                content_type: 'application/json'})
    thermostats = JSON.parse response
    $logger.info thermostats

    influxdb = InfluxDB::Client.new 'nest'

    thermostats.values.each { |ts|
      # ambient_temperature_f => 73
      # hvac_state => "heating", "cooling", "off"
      # last_connection => "2018-10-15T03:53:54.097Z"

      timestamp = DateTime.parse(ts['last_connection']).to_time.to_i

      if not ts['hvac_mode'].nil?
        data = {
          values: { value: ts['hvac_mode'] },
          tags:   { name_long: ts['name_long'] },
          timestamp: timestamp
        }
        influxdb.write_point('hvac_mode', data)
      end

      if not ts['hvac_state'].nil?
        data = {
          values: { value: ts['hvac_state'] },
          tags:   { name_long: ts['name_long'] },
          timestamp: timestamp
        }
        influxdb.write_point('hvac_state', data)
      end

      if not ts['ambient_temperature_f'].nil?
        data = {
          values: { value: ts['ambient_temperature_f'].to_f },
          tags:   { name_long: ts['name_long'] },
          timestamp: timestamp
        }
        influxdb.write_point('ambient_temperature_f', data)
      end

      if not ts['humidity'].nil?
        data = {
          values: { value: ts['humidity'].to_i },
          tags:   { name_long: ts['name_long'] },
          timestamp: timestamp
        }
        influxdb.write_point('humidity', data)
      end
    }
  end
end

Nest.start
