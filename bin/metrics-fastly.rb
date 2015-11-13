#! /usr/bin/env ruby
#
#   metrics-fastly.rb
#
# DESCRIPTION:
#
# OUTPUT:
#   plain text, metric data, etc
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#
# USAGE:
#
# NOTES:
#
# LICENSE:
#   Scott Medefind smedefind@optoro.com
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#
require 'sensu-plugin/metric/cli'
require 'net/https'
require 'uri'
require 'cgi'
require 'json'
require 'pp'

class FastlyMetrics < Sensu::Plugin::Metric::CLI::Graphite
  option :user,
         description: 'Fastly user account, requires --password',
         short: '-u USER',
         long: '--user USER'

  option :password,
         description: 'Fastly user account\'s password. Used with --user',
         short: '-p PASSWORD',
         long: '--password PASSWORD'

  option :key,
         description: 'Fastly API Key',
         short: '-k KEY',
         long: '--key'

  option :from,
         description: 'A date to start gather the metrics from, use\'s chronic parsing',
         short: '-f TIME',
         long: '--from TIME'

  option :to,
         description: 'A date to start gather the metrics from, use\'s chronic parsing',
         short: '-t TIME',
         long: '--to TIME'

  option :by,
         description: 'Sample rate of metrics, date ranges vary by rate. minute => 30 mins ago to now, hour => 1 day ago to now, day => 1 month ago to now',
         short: '-b RATE',
         long: '--by RATE',
         in: %w(minute hour day),
         default: 'day'

  option :region,
         description: 'Limit the query to a certain region',
         short: '-r REGION',
         long: '--region REGION',
         in: %w(usa europe anzac africa asia latam)

  option :schema,
         description: 'Metric naming scheme, text to prepend to metric',
         short: '-c SCHEME',
         long: '--scheme SCHEME',
         default: "#{Socket.gethostname}.fastly"

  option :field,
         description: 'Fetch specific field',
         short: '-d FIELD',
         long: '--field FIELD'

  option :aggregate,
         description: 'Fetch stats aggregated across all services',
         short: '-a',
         long: '--aggregate',
         boolean: true

  option :service,
         description: 'Fetch a specific service, must be it\'s ID. Not name',
         short: '-s SERVICE_ID',
         long: '--service SERVICE_ID'

  option :usage,
         description: 'Fetch usage across all services grouped by region',
         short: '-g',
         long: '--usage',
         boolean: true

  option :service_usage,
         description: 'Fetch usage across all services grouped by service',
         short: '-v',
         long: '--usage-service',
         boolean: true

  option :translate,
         description: 'Translate Service IDs into Service Names (Performance Hit)',
         short: '-n',
         long: '--translate',
         boolean: true,
         default: false

  # rubocop:disable AbcSize
  def run
    # Global variable for storing looked up Service IDs
    # Minimizing number of API calls
    @fastly_services = {}

    unless config[:key] || (config[:user] && config[:password])
      puts 'A Fastly API Key or username and password are required'
      exit(1)
    end

    uri = URI.parse('https://api.fastly.com')
    @http = Net::HTTP.new(uri.host, uri.port)
    @http.use_ssl = true
    @http.verify_mode = OpenSSL::SSL::VERIFY_PEER

    if config[:user] && config[:password]
      request = Net::HTTP::Post.new('/login')
      request['Content-Type'] = 'application/x-www-form-urlencoded'
      request.set_form_data(user: config[:user], password: config[:password])

      response = @http.request(request)
      @cookie = response.response['set-cookie']
    end

    # Create parameters string
    params = {
      'by' => config[:by],
      'to' => config[:to],
      'from' => config[:from],
      'region' => config[:region]
    }.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" if v }.join('&').squeeze('&')

    # Build query path
    path = 'stats'

    if config[:service]
      path.concat("/service/#{config[:service]}")
    end
    if config[:field]
      path.concat("/field/#{config[:field]}")
    end
    if config[:aggregate]
      path = 'stats/aggregate'
    end
    if config[:usage]
      path = 'stats/usage'
    end
    if config[:service_usage]
      path = 'stats/usage_by_service'
    end

    request = Net::HTTP::Get.new("/#{path}?#{params}")
    request['Content-Type'] = 'application/json'

    request = login_headers(request)
    response = @http.request(request)
    fastly_data = JSON.parse(response.body)

    # Parse Fastly's JSON data
    if fastly_data['data'].is_a?(Hash)

      fastly_data['data'].each_key do |key|
        if fastly_data['data'][key].is_a?(Array)

          fastly_data['data'][key].each do |metrics|
            timestamp = metrics['start_time']
            service_id = translate_service(metrics['service_id'])
            metrics.delete('start_time')
            metrics.delete('service_id')

            metrics.each_key do |metric_key|
              output "#{config[:schema]}.#{service_id}.#{metric_key}", metrics[metric_key], timestamp
            end
          end
        elsif fastly_data['data'][key].is_a?(Hash)

          fastly_data['data'][key].each_key do |service_id|
            if fastly_data['data'][key][service_id].is_a?(Hash)

              fastly_data['data'][key][service_id].each_key do |metrics|
                output "#{config[:schema]}.#{key}.#{translate_service(service_id)}.#{metrics}", fastly_data['data'][key][service_id][metrics]
              end

            else
              output "#{config[:schema]}.#{key}.#{metrics}", fastly_data['data'][key][metrics]
            end
          end
        end
      end
    elsif fastly_data['data'].is_a?(Array)

      fastly_data['data'].each do |metrics|
        timestamp = metrics['start_time']
        metrics.delete('start_time')

        if metrics.key?('service_id')
          service_id = translate_service(metrics['service_id'])
          metrics.delete('service_id')
        end

        metrics.each_key do |metric_key|
          if service_id
            prefix = "#{service_id}.#{metric_key}"
          else
            prefix = metric_key
          end
          output "#{config[:schema]}.#{prefix}", metrics[metric_key], timestamp
        end
      end
    end
    ok
  end

  # Converts Service ID into it's name and remove . and spaces for _
  def translate_service(service_id)
    if config[:translate]

      # Check if Service ID was already translated
      if @fastly_services[service_id]

        result = @fastly_services[service_id]

      else

        request = Net::HTTP::Get.new("/service/#{service_id}")
        request['Content-Type'] = 'application/json'
        request = login_headers(request)

        response = @http.request(request)
        service_data = JSON.parse(response.body)

        if service_data['name']
          result = service_data['name'].tr('.\ ', '_')
          @fastly_services['service_id'] = result
        else
          result = service_id
        end
      end

      if result == ''
        service_id
      else
        result
      end
    else
      service_id
    end
  end

  # Set login headers based on login method
  def login_headers(request)
    if @cookie
      request['Cookie'] = @cookie
    else
      request['Fastly-Key'] = config[:key]
    end

    request
  end
end
