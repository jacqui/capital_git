$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'capital_git'
require 'time'

CapitalGit.logger.level = Logger::ERROR
ENV["CAPITAL_GIT_ENV"] = "test"

require 'minitest/autorun'
require 'minitest/mock'
