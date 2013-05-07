require 'yaml'
require 'twilio-ruby'
require 'iron_cache'
# Requires manual installation of the New Relic plaform gem (platform is in closed beta)
# https://github.com/newrelic-platform/iron_sdk
require 'newrelic_platform'

# Setup

# Twilio calls statuses
TWILIO_CALL_STATUSES = %w(queued ringing in-progress canceled completed failed busy no-answer)
TWILIO_SMS_STATUSES = %w(queued sending sent failed received)


# configure Twilio client
@twilio = Twilio::REST::Client.new(config['twilio']['account_sid'],
                                   config['twilio']['auth_token'])

# configure NewRelic client
new_relic = NewRelic::Client.new(:license => config['newrelic']['license'],
                                 :guid => config['newrelic']['guid'],
                                 :version => config['newrelic']['version'])

@collector = new_relic.new_collector

# configure IronCache client
ic = IronCache::Client.new(config['iron'])
@cache = ic.cache("newrelic-twilio-agent")

# helpers

def duration(prev, current)
  prev ? (current - prev).to_i : 60
end

def add_component_data(name, metric, data, since)
  component = @collector.component(name)

  data.each_pair do |key, value|
    component.add_metric(key, metric, value)
  end
  processed_at = Time.now

  component.options[:duration] = duration(since, processed_at)

  processed_at
end

# Process data

# get previous run time
calls_prev_at = @cache.get('calls_previously_processed_at')
sms_prev_at = @cache.get('sms_previously_processed_at')

# since before yesterday midnight
today = Time.now.strftime('%Y-%m-%d')
before_yesterday = (Time.now - 2 * 24 * 3600).strftime('%Y-%m-%d')

# calls
calls_stats = {}
TWILIO_CALL_STATUSES.each do |call_status|
  opts = {:status => call_status}
  if ['queued', 'in-progress'].include?(call_status)
    # total for last two days for (still queued/in-progress)
    opts[:"start_time>"] = before_yesterday
  else
    opts[:start_time] = today
  end

  calls_stats[call_status] = @twilio.account.calls.list(opts).total
end

calls_processed_at = add_component_data('Today Calls', 'calls', call_status, calls_prev_at)

# SMS
sms_stats = TWILIO_SMS_STATUSES.each_with_object({}) { |s, res| res[s] = 0 }
# Twilio has no filter by status for SMS logs,
# this could be very slow on huge SMS amount
@twilio.account.sms.messages.list({:date_sent => today}) do |msg|
  sms_stats[msg.status.to_s] += 1
end

sms_processed_at = add_component_data('Today SMS', 'messages', sms_stats, sms_prev_at)

# send data to NewRelic
@collector.submit

# update cache timestamps
@cache.put('calls_previously_processed_at', calls_processed_at)
@cache.put('sms_previously_processed_at', sms_processed_at)
