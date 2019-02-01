#!/usr/bin/env ruby

# Automates the check-in process for Southwest flights
#
# Uses a headless chrome browser powered by `chromedriver` and optionally emails
# you a screenshot of the result (hopefully a successful check-in)
#
# === Dependencies
#
#   1. Ruby (heavily recommend installing Ruby with RVM: rvm.io)
#
#   2. `selenium-webdriver` ruby gem. Install with `gem install selenium-webdriver`
#
#   3. `chromedriver`
#       Debian Linux: https://christopher.su/2015/selenium-chromedriver-ubuntu
#       OSX: `brew install chromedriver`
#
#   4. `sendemail`
#       Project: http://caspian.dotconf.net/menu/Software/SendEmail
#       Debian Linux: `apt-get install libio-socket-ssl-perl libnet-ssleay-perl sendemail`
#       OSX: `brew install sendemail`
#
# === Running
#
# The script requires your name and Southwest confirmation code to run.
#
#     SWA_CONFIRMATION="T9MUNA" SWA_NAME="Darth Vadar" path/to/swa.rb
#
# === Mailing the results
#
# You can optionally specify SMTP email information to have the results
# emailed back to you (success or failure). Requires specifying all the
# SWA_EMAIL_* configs
#
# NOTE: This step requires SMTP credentials which could be exposed in your
# servers command history. It is recommended that you use a junkmail
# account (e.g. Yahoo) as the sender and not your real account.
#
# - SMTP Server: Yahoo uses `smtp.mail.yahoo.com:587` and Gmail uses
#   `smtp.gmail.com:587`
# - Username: The full email used to log in. Will be the email sender.
# - Password: Your email login password
# - Recipients: Space separate list of recipients
#
#     SWA_CONFIRMATION="T9MUNA" \
#       SWA_NAME="Darth Vadar" \
#       SWA_EMAIL_SERVER="smtp.foo.com:587" \
#       SWA_EMAIL_USER="from@example.com" \
#       SWA_EMAIL_PASSWORD="blahBlah" \
#       SWA_EMAIL_RECIPIENTS="person1@example.com person2@example.com" \
#       path/to/swa.rb
#
# === Scheduling
#
#  You can use `cron` on any other scheduling utility to run this script

require "selenium-webdriver"
require "shellwords"

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
      checkin_el = driver.find_element(id: "booking-form--check-in-tab")
      checkin_el.click

      logger.debug("Fill out flight info")

      confirmation_field = driver.find_element(id: "confirmationNumber")
      fname_field = driver.find_element(id: "firstName")
      lname_field = driver.find_element(id: "lastName")
      submit = driver.find_element(id: "jb-button-check-in")

      confirmation_field.send_keys(confirmation)
      fname_field.send_keys(fname)
      lname_field.send_keys(lname)
      submit.click

      sleep 3.0

      raise "Southwest Application Error" if page_has_error?

      # There's no id for this button element, but for now it's the only
      # `submit-button` class on the page. Fingers crossed it stays that way.
      submit = driver.find_element(:class, "submit-button")
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
    @logger = Logger.new(@logger_filepath)
    @logger.info("Logging enabled")
  end

  def setup_driver
    logger.debug("Creating driver")

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    @driver = Selenium::WebDriver.for(:chrome, options: options)
  end

  def setup_headless_window
    width = 1600
    height = 1280
    logger.debug("Resizing window to #{width}x#{height}")
    driver.manage.window.resize_to(width, height)
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
    driver.navigate.to(url)
  end

  def page_has_error?
    # In several cases the Southwest website returns a page with an
    # error flash/div at the top. This occurs when the check in doesn't exist,
    # is too early, has already passed, etc...
    driver.find_elements(class: "message_error").any?
  end

  def capture_screenshot!
    @screenshot_filename = "screenshot-#{Time.now.utc.to_i}.png"
    @screenshot_filepath = File.join("/tmp", @screenshot_filename)

    logger.debug "Capturing screenshot... #{@screenshot_filepath}"
    puts "Capturing screenshot... #{@screenshot_filepath}"
    driver.save_screenshot(@screenshot_filepath) if driver
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
      "-a", @screenshot_filepath
    ].join(" ")

    logger.debug("sendemail command: '#{cmd}'")
    `#{cmd}`
  end

  def escape(str)
    Shellwords.escape(str)
  end
end

SouthwestCheckInTask.new.run!
