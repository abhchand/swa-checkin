#!/usr/bin/env ruby

#   _____  ___   __ __  ______  __ __  __    __    ___  _____ ______
#  / ___/ /   \ |  |  ||      ||  |  ||  |__|  |  /  _]/ ___/|      |
# (   \_ |     ||  |  ||      ||  |  ||  |  |  | /  [_(   \_ |      |
#  \__  ||  O  ||  |  ||_|  |_||  _  ||  |  |  ||    _]\__  ||_|  |_|
#  /  \ ||     ||  :  |  |  |  |  |  ||  `  '  ||   [_ /  \ |  |  |
#  \    ||     ||     |  |  |  |  |  | \      / |     |\    |  |  |
#   \___| \___/  \__,_|  |__|  |__|__|  \_/\_/  |_____| \___|  |__|

require "dotenv/load"
require "capybara"
require "shellwords"
require "logger"
require "optparse"

# dotenv looks for an `.env` file in the current working directory, which
# may not be the same directory this file is located in (e.g when running
# with cron). Specify the fully qualified `.env` file path explicitly
ENV_FILE = (File.expand_path(File.dirname(__FILE__)) + "/.env").freeze
Dotenv.load(ENV_FILE)

class SouthwestCheckInTask
  MAX_RETRIES = 3

  attr_accessor :logger, :session, :config

  def initialize(options = {})
    @now = Time.now.to_i

    @max_retries = (options[:max_retries] || MAX_RETRIES).to_i
    raise "Invalid value for `--max-retries`" if @max_retries < 1

    setup_logger

    validate_environment

    check_for_chromedriver
    check_for_sendemail
  end

  def run!
    run_and_close_session do
      logger.info("Visiting SWA website")
      visit("https://southwest.com")

      logger.debug("Clicking Check-In Tab")
      checkin_el = session.find(id: "TabbedArea_4-tab-4")
      checkin_el.click

      logger.debug("Fill out flight info")

      confirmation_field = session.find(id: "LandingPageAirReservationForm_confirmationNumber_check-in")
      confirmation_field.send_keys(confirmation)

      fname_field = session.find(id: "LandingPageAirReservationForm_passengerFirstName_check-in")
      fname_field.send_keys(fname)

      lname_field = session.find(id: "LandingPageAirReservationForm_passengerLastName_check-in")
      lname_field.send_keys(lname)

      submit = session.find(id: "LandingPageAirReservationForm_submit-button_check-in")
      submit.click

      raise "Southwest Application Error: #{@swa_error_message || 'unknown'}" if page_has_error?

      # There's no id for this button element, but for now it's the only
      # `submit-button` class on the page. Fingers crossed it stays that way.
      submit = session.find(:css, ".form-mixin--submit-button")
      submit.click

      sleep 3.0

      @success = true
    end
  end

  private

  def confirmation
    @confirmation ||= ENV["SWA_CONFIRMATION"]&.upcase
  end

  def fname
    @fname ||= ENV["SWA_NAME"]&.split(" ", 2)&.first
  end

  def lname
    @lname ||= ENV["SWA_NAME"]&.split(" ", 2)&.last
  end

  def email_server
    @email_server ||= ENV["SWA_EMAIL_SERVER"]
  end

  def email_sender
    @email_sender ||= ENV["SWA_EMAIL_USER"]
  end

  def email_password
    @email_password ||= ENV["SWA_EMAIL_PASSWORD"]
  end

  def email_recipients
    @email_recipients ||= ENV["SWA_EMAIL_RECIPIENTS"]&.gsub(/,/, " ")
  end

  def email_subject
    @email_subject ||=
      if @success
        "Southwest Check In Completed for #{fname}"
      else
        "Southwest Check In Failed for #{fname}"
      end
  end

  def validate_environment
    logger.debug("Checking if ENV variables are set")

    if !confirmation || !fname || !lname
      logger.fatal("Please set `SWA_CONFIRMATION` and `SWA_NAME`")
      exit(1)
    end
  end

  def check_for_chromedriver
    logger.debug("Checking if `chromedriver` is available")

    if !`which chromedriver`
      logger.fatal("Can not find `chromedriver`")
      exit(1)
    end
  end

  def check_for_sendemail
    logger.debug("Checking if `sendemail` is available")

    if !`which sendemail`
      logger.fatal("Can not find `sendemail`")
      exit(1)
    end
  end

  def setup_logger
    @logger_filepath = "/tmp/swa-#{@now}.log"
    puts "Logging to #{@logger_filepath}"
    @logger = ::Logger.new(@logger_filepath)
    @logger.info("Logging enabled")
  end

  def setup_session
    logger.debug("Creating session")
    @session = Capybara::Session.new(:selenium_chrome_headless)
  end

  def setup_headless_window
    width = 1600
    height = 1280
    logger.debug("Resizing window to #{width}x#{height}")
    session.current_window.resize_to(width, height)
  end

  def close_session
    if session
      logger.info("Closing session...")
      session.driver.quit
    end
  end

  def reset_session
    logger.info("Resetting session...")
    close_session
  end

  # Executes a block and ensures the headless browser connection is closed
  # before exiting.
  def run_and_close_session(&block)
    @attempt = 1

    begin
      setup_session
      setup_headless_window

      logger.info("Starting execution (Attempt #{@attempt} of #{@max_retries})")
      yield
      logger.info "Complete!"
    rescue => e
      logger.error e

      if @attempt < @max_retries
        capture_page!
        capture_screenshot!
        sleep(@attempt * 3)
        close_session
        @attempt += 1
        retry
      end
    ensure
      capture_page!
      capture_screenshot!

      close_session

      send_mail
    end
  end

  def visit(url, log: true)
    logger.debug("Visiting #{url}") if log
    session.visit(url)
  end

  def page_has_error?
    # In several cases the Southwest website returns a page with an
    # error flash/div at the top. This occurs when the check in doesn't exist,
    # is too early, has already passed, etc...
    error = session.find(:css, ".message_error")
    @swa_error_message = error.text.split("\n").first.strip
  rescue Capybara::ElementNotFound => e
    false
  end

  def capture_page!
    page = "/tmp/swa-#{@now}-#{@attempt}.html"

    logger.debug "Capturing page #{@attempt}... #{page}"
    puts "Capturing page #{@attempt}... #{page}"

    File.open(page, "w") { |file| file.write(session.body) }
    @pages ||= []
    @pages << page
  end

  def capture_screenshot!
    screenshot = "/tmp/screenshot-#{@now}-#{@attempt}.png"

    logger.debug "Capturing screenshot #{@attempt}... #{screenshot}"
    puts "Capturing screenshot #{@attempt}... #{screenshot}"

    if session
      session.save_screenshot(screenshot)
      @screenshots ||= []
      @screenshots << screenshot
    end
  end

  def send_mail?
    email_server && email_sender && email_password && email_recipients
  end

  def send_mail
    return unless send_mail?

    body = "This email was generated automatically by a bot\n" +
      "I attempted to check in #{@attempt} time(s)\n" +
      "Please see attached results\n\n"

    cmd = [
      "sendemail",
      "-f", "-f", "\"SWA Check In Script <#{email_sender}>\"",
      "-t", email_recipients,
      "-u", email_subject,
      "-m", escape(body),
      "-o", "tls=yes",
      "-s", email_server,
      "-xu", email_sender,
      "-xp", escape(email_password)
    ]

    (@screenshots + @pages + [@logger_filepath]).each do |attachment|
      cmd << "-a"
      cmd << attachment
    end

    cmd = cmd.join(" ")

    logger.debug("sendemail command: '#{cmd}'")
    `#{cmd}`
  end

  def escape(str)
    Shellwords.escape(str)
  end

  def page
    Capybara.current_session
  end
end

options = {}

parser = OptionParser.new do |opts|
  opts.banner = "\nUsage: #{__FILE__} [options]"

  options[:max_retries] = SouthwestCheckInTask::MAX_RETRIES
  opts.on(
    "-rMAX_RETRIES",
    "--max-retries=MAX_RETRIES",
    "Maximum number of times to retry "\
      "(default: #{SouthwestCheckInTask::MAX_RETRIES})"
  ) do |c|
    options[:max_retries] = c
  end

  opts.on("-h", "--help", "Prints this help") do
    puts opts
    exit
  end
end

parser.parse!
SouthwestCheckInTask.new(options).run!
