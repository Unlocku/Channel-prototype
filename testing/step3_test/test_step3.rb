require_relative "../miscellaneous/libs/gpctest.rb"
require_relative "../../message_sender_bot/message_sender_bot.rb"
require "minitest/autorun"
require "mongo"
require "bigdecimal"

# A is sender and B is listener

Mongo::Logger.logger.level = Logger::FATAL

class Step3 < Minitest::Test
  def establish_step3(file_name)
    begin
      @private_key_A = "0x63d86723e08f0f813a36ce6aa123bb2289d90680ae1e99d4de8cdb334553f24d"
      @private_key_B = "0xd00c06bfd800d27397002dca6fb0993d5ba6399b4238b2f29ee9deb97593d2bc"
      @path_to_file = __dir__ + "/../miscellaneous/files/"
      @logger = Logger.new(@path_to_file + "gpc.log")
      @client = Mongo::Client.new(["127.0.0.1:27017"], :database => "GPC")
      @db = @client.database

      data_raw = File.read(__dir__ + "/" + file_name)
      data_json = JSON.parse(data_raw, symbolize_names: true)

      msg_1 = data_json[:A][:msg_1]
      msg_3 = data_json[:A][:msg_3]
      cells_spent_A = data_json[:A][:spent_cell] == nil ? nil : data_json[:A][:spent_cell].map { |cell| CKB::Types::OutPoint.from_h(cell) }

      funding_B = data_json[:B][:amount]
      fee_B = data_json[:B][:fee]
      cells_spent_B = data_json[:B][:spent_cell] == nil ? nil : data_json[:B][:spent_cell].map { |cell| CKB::Types::OutPoint.from_h(cell) }
      ip_B = data_json[:B][:ip]
      listen_port_B = data_json[:B][:port]

      expect = JSON.parse(data_json[:expect_info], symbolize_names: true) if data_json[:expect_info] != nil

      tests = Gpctest.new("test")
      tests.setup()
      commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
                   recv_fund_fee: fee_B, sender_one_way_permission: "yes",
                   payment_reply: "yes", closing_reply: "yes" }
      tests.create_commands_file(commands)
      tests.init_client()
      @monitor_B, @listener_B = tests.start_listen_monitor_B()

      # spend cells.
      tests.spend_cell("A", cells_spent_A)
      tests.spend_cell("B", cells_spent_B)
      # Since we test step 1, we needs to act as A.
      bot = Sender_bot.new(@private_key_A)
      bot.send_msg(ip_B, listen_port_B, [msg_1, msg_3])
      sleep(2)
      if expect != nil
        for expect_iter in expect
          result_json = tests.load_json_file(@path_to_file + "result.json").to_json
          assert_match(expect_iter.to_json[1..-2], result_json, "#{expect_iter[1..-2]}")
        end
      end
    rescue => exception
      puts exception
    ensure
      tests.close_all_thread(0, @monitor_B, @db)
    end
  end

  def test_success()
    establish_step3("test_step3_success.json")
  end

  def test_gpc_arg_modified()
    establish_step3("test_step3_gpc_arg_modified.json")
  end

  def test_signature_invalid()
    establish_step3("test_step3_signature_invalid.json")
  end

  # def test_amount_negtive()
  #   establish_step1("test_step1_amount_negtive.json")
  # end

  # def test_fee_negtive()
  #   establish_step1("test_step1_fee_negtive.json")
  # end

  # def test_change_container_insufficient()
  #   establish_step1("test_step1_change_container_insufficient.json")
  # end

  # def test_settle_continer_insufficient()
  #   establish_step1("test_step1_settle_container_insufficient.json")
  # end

  # def test_cell_dead()
  #   establish_step1("test_step1_cell_dead.json")
  # end

  # def test_capacity_inconsistent()
  #   establish_step1("test_step1_capacity_inconsistent.json")
  # end
end