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

class SouthwestCheckInTask
  attr_accessor :logger, :driver, :config

  def initialize
    setup_logger

    validate_environment

    check_for_chromedriver
    check_for_sendemail
    setup_driver
    setup_headless_window
  end

  def run!
    run_and_close_driver do
      logger.info("Visiting SWA website")
      visit("https://southwest.com")

      logger.debug("Clicking Check-In Tab")
      checkin_el = driver.find(id: "TabbedArea_4-tab-4")
      checkin_el.click

      logger.debug("Fill out flight info")

      confirmation_field = driver.find(id: "LandingPageAirReservationForm_confirmationNumber_check-in")
      confirmation_field.send_keys(confirmation)

      fname_field = driver.find(id: "LandingPageAirReservationForm_passengerFirstName_check-in")
      fname_field.send_keys(fname)

      lname_field = driver.find(id: "LandingPageAirReservationForm_passengerLastName_check-in")
      lname_field.send_keys(lname)

      submit = driver.find(id: "LandingPageAirReservationForm_submit-button_check-in")
      submit.click

      raise "Southwest Application Error" if page_has_error?

      # There's no id for this button element, but for now it's the only
      # `submit-button` class on the page. Fingers crossed it stays that way.
      submit = driver.find(:css, ".form-mixin--submit-button")
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
    @logger_filepath = "/tmp/swa-#{Time.now.utc.to_i}.log"
    puts "Logging to #{@logger_filepath}"
    @logger = ::Logger.new(@logger_filepath)
    @logger.info("Logging enabled")
  end

  def setup_driver
    logger.debug("Creating driver")
    @driver = Capybara::Session.new(:selenium_chrome_headless)
  end

  def setup_headless_window
    width = 1600
    height = 1280
    logger.debug("Resizing window to #{width}x#{height}")
    driver.current_window.resize_to(width, height)
  end

  # Executes a block and ensures the headless browser connection is closed
  # before exiting.
  def run_and_close_driver(&block)
    logger.info("Starting execution")
    yield
    logger.info "Complete!"
  rescue => e
    logger.error e
    logger.error e.backtrace
    logger.debug "Page Body:"
    logger.debug driver.body
  ensure
    capture_screenshot!

    if driver
      logger.info("Closing driver...")
      driver.quit
    end

    send_mail
  end

  def visit(url, log: true)
    logger.debug("Visiting #{url}") if log
    driver.visit(url)
  end

  def page_has_error?
    # In several cases the Southwest website returns a page with an
    # error flash/div at the top. This occurs when the check in doesn't exist,
    # is too early, has already passed, etc...
    driver.find(:css, ".message_error")
    true
  rescue Capybara::ElementNotFound => e
    false
  end

  def capture_screenshot!
    @screenshot_filename = "/tmp/screenshot-#{Time.now.utc.to_i}.png"

    logger.debug "Capturing screenshot... #{@screenshot_filename}"
    puts "Capturing screenshot... #{@screenshot_filename}"

    driver.save_screenshot(@screenshot_filename) if driver
  end

  def send_mail?
    email_server && email_sender && email_password && email_recipients
  end

  def send_mail
    return unless send_mail?

    body = "This email was generated automatically by a bot\n" +
      "Please see attached results\n\n" +
      File.read(@logger_filepath)

    cmd = [
      "sendemail",
      "-f", "-f", "\"SWA Check In Script <#{email_sender}>\"",
      "-t", email_recipients,
      "-u", email_subject,
      "-m", escape(body),
      "-o", "tls=yes",
      "-s", email_server,
      "-xu", email_sender,
      "-xp", escape(email_password),
      "-a", @screenshot_filename
    ].join(" ")

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

SouthwestCheckInTask.new.run!
