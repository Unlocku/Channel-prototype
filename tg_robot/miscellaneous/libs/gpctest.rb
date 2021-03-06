require "rubygems"
require "bundler/setup"
require "minitest/autorun"
require "mongo"
require "json"
require "ckb"
require "logger"
require_relative "types.rb"

# udt_code: https://github.com/ZhichunLu-11/ckb-gpc-contract/blob/f39fd7774019d0333857f8e6861300a67fb1e266/c/simple_udt.c
# note that I change the byte of amount in UDT from 16 to 8.

# gpc_code https://github.com/ZhichunLu-11/ckb-gpc-contract/blob/f39fd7774019d0333857f8e6861300a67fb1e266/main.c

# The two account are test account in ckb-dev.

# # issue for random generated private key: d00c06bfd800d27397002dca6fb0993d5ba6399b4238b2f29ee9deb97593d2bc
# [[genesis.issued_cells]]
# capacity = 20_000_000_000_00000000
# lock.code_hash = "0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8"
# lock.args = "0xc8328aabcd9b9e8e64fbc566c4385c3bdeb219d7"
# lock.hash_type = "type"

# # issue for random generated private key: 63d86723e08f0f813a36ce6aa123bb2289d90680ae1e99d4de8cdb334553f24d
# [[genesis.issued_cells]]
# capacity = 5_198_735_037_00000000
# lock.code_hash = "0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8"
# lock.args = "0x470dcdc5e44064909650113a274b3b36aecb6dc7"
# lock.hash_type = "type"

# note that A is users and B is robot.
# A send establishment request to B and then the channel established.

$VERBOSE = nil

class Gpctest < Minitest::Test
  def initialize(name)
    super(name)

    @path_to_binary = __dir__ + "/../binary/"
    @path_to_file = __dir__ + "/../files/"
    @path_to_user = __dir__ + "/../../User/GPC"
    @path_to_robot = __dir__ + "/../../Robot/GPC"

    @api = CKB::API::new
    @rpc = CKB::RPC.new

    @secp_args_A = "0x470dcdc5e44064909650113a274b3b36aecb6dc7"
    @private_key_A = "0x63d86723e08f0f813a36ce6aa123bb2289d90680ae1e99d4de8cdb334553f24d"
    @pubkey_A = "0x038d3cfceea4f9c2e76c5c4f5e99aec74c26d6ac894648b5700a0b71f91f9b5c2a"
    @ip_A = "127.0.0.1"

    @secp_args_B = "0xc8328aabcd9b9e8e64fbc566c4385c3bdeb219d7"
    @private_key_B = "0xd00c06bfd800d27397002dca6fb0993d5ba6399b4238b2f29ee9deb97593d2bc"
    @pubkey_B = "0x03fe6c6d09d1a0f70255cddf25c5ed57d41b5c08822ae710dc10f8c88290e0acdf"
    @ip_B = "127.0.0.1"

    @default_lock_A = CKB::Types::Script.new(code_hash: CKB::SystemCodeHash::SECP256K1_BLAKE160_SIGHASH_ALL_TYPE_HASH,
                                             args: @secp_args_A, hash_type: CKB::ScriptHashType::TYPE)
    @default_lock_B = CKB::Types::Script.new(code_hash: CKB::SystemCodeHash::SECP256K1_BLAKE160_SIGHASH_ALL_TYPE_HASH,
                                             args: @secp_args_B, hash_type: CKB::ScriptHashType::TYPE)

    @client = Mongo::Client.new(["127.0.0.1:27017"], :database => "GPC")
    @db = @client.database
    @coll_session_A = @db[@pubkey_A + "_session_pool"]
    @coll_session_B = @db[@pubkey_B + "_session_pool"]

    @listen_port_A = 1000
    @listen_port_B = 2000

    @wallet_A = CKB::Wallet.from_hex(@api, @private_key_A)
    @wallet_B = CKB::Wallet.from_hex(@api, @private_key_B)
    @type_script_hash = load_type()
    @logger = Logger.new(@path_to_file + "gpc.log")
  end

  def record_result(result)
    data_hash = {}
    if File.file?(@path_to_file + "result.json")
      data_raw = File.read(@path_to_file + "result.json")
      data_hash = JSON.parse(data_raw, symbolize_names: true)
    end
    data_hash = data_hash.merge(result)
    data_json = data_hash.to_json
    file = File.new(@path_to_file + "result.json", "w")
    file.syswrite(data_json)
  end

  def load_id()
    data_hash = {}
    if File.file?(@path_to_file + "result.json")
      data_raw = File.read(@path_to_file + "result.json")
      data_hash = JSON.parse(data_raw, symbolize_names: true)
    end
    return data_hash[:id]
  end

  def record_info_in_db()
    id = load_id()
    @logger.info("The id of channel is #{id}")
    record_A = @coll_session_A.find({ id: id })
    record_B = @coll_session_B.find({ id: id })

    if record_A.first != nil
      record_result({ sender_status: record_A.first[:status] })
    else
      record_result({ sender_status: "none" })
    end

    if record_B.first != nil
      record_result({ receiver_status: record_B.first[:status] })
    else
      record_result({ receiver_status: "none" })
    end
  end

  def generate_blocks(rpc, num, interval = 0)
    for i in 0..num
      rpc.generate_block
      sleep(interval)
    end
    return true
  end

  def get_minimal_capacity(lock, type, output_data)
    output = CKB::Types::Output.new(
      capacity: 0,
      lock: lock,
      type: type,
    )
    return 0 if lock == nil
    return output.calculate_min_capacity(output_data)
  end

  def deploy_contract(data)
    code_hash = CKB::Blake2b.hexdigest(data)
    data_size = data.bytesize
    tx_hash = @wallet_A.send_capacity(@wallet_A.address, CKB::Utils.byte_to_shannon(data_size + 10000), CKB::Utils.bin_to_hex(data), fee: 10 ** 6)
    return [code_hash, tx_hash]
  end

  def spend_cell(party, inputs)
    return false if inputs == nil
    outputs = []
    outputs_data = []
    witnesses = []

    tx = CKB::Types::Transaction.new(
      version: 0,
      cell_deps: [],
      inputs: [],
      outputs: nil,
      outputs_data: nil,
      witnesses: nil,
    )

    for input in inputs
      previous_tx = @api.get_transaction(input.tx_hash).transaction
      previous_output = previous_tx.outputs[input.index]

      # construct output
      output = CKB::Types::Output.new(
        capacity: previous_output.capacity - 3000,
        lock: previous_output.lock,
        type: previous_output.type,
      )
      # add output, output_data and witness

      outputs << output
      outputs_data << previous_tx.outputs_data[input.index]
      witnesses << CKB::Types::Witness.new

      tx.inputs << CKB::Types::Input.new(
        previous_output: input,
        since: 0,
      )
    end
    tx.cell_deps << CKB::Types::CellDep.new(out_point: @api.secp_code_out_point, dep_type: "code")
    tx.cell_deps << CKB::Types::CellDep.new(out_point: @api.secp_data_out_point, dep_type: "code")
    tx.cell_deps << load_type_dep()

    tx.outputs = outputs
    tx.outputs_data = outputs_data
    tx.witnesses = witnesses

    tx.hash = tx.compute_hash

    # sign the tx
    if party == "A"
      signed_tx = tx.sign(@wallet_A.key)
    elsif party == "B"
      signed_tx = tx.sign(@wallet_B.key)
    end

    @api.send_transaction(signed_tx)
    generate_blocks(@rpc, 5)
  end

  # here I setup the environment for testing.
  # 1. deploy the gpc contract.
  # 2. deploy the udt contract.
  # 3. create and disseminate UDT to two account.
  def setup
    # back to 0 block.
    @rpc.truncate("0x823b2ff5785b12da8b1363cac9a5cbe566d8b715a4311441b119c39a0367488c")
    local_height = @api.get_tip_block_number
    # generate 5 blocks to enable the initial cells can be spent.
    generate_blocks(@rpc, 5)

    # send gpc contract to the chain.
    gpc_data = File.read(@path_to_binary + "gpc")
    gpc_code_hash, gpc_tx_hash = deploy_contract(gpc_data)
    generate_blocks(@rpc, 5)

    # send udt contract to the chain.
    udt_data = File.read(@path_to_binary + "simple_udt")
    udt_code_hash, udt_tx_hash = deploy_contract(udt_data)

    # ensure the tx onchain.
    tx_checked = [gpc_tx_hash, udt_tx_hash]
    while true
      generate_blocks(@rpc, 5)
      remote_height = @api.get_tip_block_number
      for i in (local_height + 1..remote_height)
        block = @api.get_block_by_number(i)
        for transaction in block.transactions
          if tx_checked.include? transaction.hash
            tx_checked.delete(transaction.hash)
          end
        end
      end
      break if tx_checked == []
    end

    # disseminate udt.
    udt_dep = CKB::Types::CellDep.new(out_point: CKB::Types::OutPoint.new(tx_hash: udt_tx_hash, index: 0))

    # send UDT randomly for ten times.
    for iter in 0..9
      tx = @wallet_A.generate_tx(@wallet_A.address, CKB::Utils.byte_to_shannon(2000), fee: 1000)
      tx.cell_deps.push(udt_dep.dup)
      # generate the udt type script.
      # set the args as the input lock to represent his is the owner, for more deteil, you can
      # have a look at the simple_udt.c.
      for input in tx.inputs
        cell = @api.get_live_cell(input.previous_output)
        next if cell.status != "live"
        input_lock = cell.cell.output.lock
        input_lock_ser = input_lock.compute_hash
        type_script = CKB::Types::Script.new(code_hash: udt_code_hash,
                                             args: input_lock_ser, hash_type: CKB::ScriptHashType::DATA)
      end

      # split the output
      outputs = tx.outputs
      first_output = outputs[0]
      first_output.capacity = get_minimal_capacity(@default_lock_A, type_script, CKB::Utils.bin_to_hex([20].pack("Q<")))
      first_output.type = type_script
      second_output = first_output.dup

      first_output.lock = @default_lock_A
      second_output.lock = @default_lock_B

      tx.outputs.delete_at(0)
      tx.outputs.insert(0, first_output)
      tx.outputs.insert(0, second_output)

      # generate UDT amount.
      tx.outputs_data[0] = CKB::Utils.bin_to_hex([20].pack("Q<"))
      tx.outputs_data[1] = CKB::Utils.bin_to_hex([20].pack("Q<"))
      tx.outputs_data << "0x"

      signed_tx = tx.sign(@wallet_A.key)
      root_udt_tx_hash = @api.send_transaction(signed_tx)
      generate_blocks(@rpc, 5)
    end

    system("rm #{@path_to_file}result.json")
    # system("rm #{@path_to_file}gpc.log")
    # record these info to json. So the gpc client can read them.
    script_info = { gpc_code_hash: gpc_code_hash, gpc_tx_hash: gpc_tx_hash,
                    udt_code_hash: udt_code_hash, udt_tx_hash: udt_tx_hash,
                    type_script: type_script.to_h.to_json }
    file = File.new(@path_to_file + "contract_info.json", "w")
    file.syswrite(script_info.to_json)
    file.close()
  end

  # get amount of asset by type and lock_hashes.
  def get_balance(lock_hashes, type_script_hash = "", decoder = nil)
    from_block_number = 0
    current_height = @api.get_tip_block_number
    amount_gathered = 0
    for lock_hash in lock_hashes
      while from_block_number <= current_height
        current_to = [from_block_number + 100, current_height].min
        cells = @api.get_cells_by_lock_hash(lock_hash, from_block_number, current_to)
        for cell in cells
          validation = @api.get_live_cell(cell.out_point)
          return nil if validation.status != "live"
          tx = @api.get_transaction(cell.out_point.tx_hash).transaction
          type_script = tx.outputs[cell.out_point.index].type
          type_script_hash_current = type_script == nil ? "" : type_script.compute_hash
          next if type_script_hash_current != type_script_hash && type_script_hash != ""
          amount_gathered += decoder == nil ?
            tx.outputs[cell.out_point.index].capacity :
            decoder.call(tx.outputs_data[cell.out_point.index])
        end
        from_block_number = current_to + 1
      end
    end
    return amount_gathered
  end

  def start_listen_monitor()
    monitor_A, listener_A = start_listen_monitor_A()
    monitor_B, listener_B = start_listen_monitor_B()
    return monitor_A, monitor_B, listener_A, listener_B
  end

  def start_listen_monitor_A()
    monitor_A = spawn("ruby " + @path_to_user + " monitor #{@pubkey_A}")
    listener_A = spawn("ruby " + @path_to_user + " listen #{@pubkey_A} #{@listen_port_A}")
    sleep(2)
    return monitor_A, listener_A
  end

  def start_listen_monitor_B()
    monitor_B = spawn("ruby " + @path_to_robot + " monitor #{@pubkey_B}")
    listener_B = spawn("ruby " + @path_to_robot + " listen #{@pubkey_B} #{@listen_port_B}")
    sleep(2)
    return monitor_B, listener_B
  end

  def send_establishment_request_A(funding_A, fee_A, since = "9223372036854775908")
    type_script_hash = load_type()
    command_input = ""
    for asset_type in funding_A.keys()
      command_input += "#{asset_type}:#{funding_A[asset_type]} "
    end
    system("ruby " + @path_to_user + " send_establishment_request --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --fee #{fee_A} --since #{since} --funding #{command_input}")
  end

  def kill_listener()
    system("lsof -ti:1000 | xargs kill")
    system("lsof -ti:2000 | xargs kill")
  end

  def kill_monitor(monitor_A, monitor_B)
    system("kill #{monitor_A}") if monitor_A != 0
    system("kill #{monitor_B}") if monitor_B != 0
  end

  def close_all_thread(monitor_A, monitor_B, db)
    kill_monitor(monitor_A, monitor_B)
    kill_listener()
    db.drop()
  end

  def init_client()
    system ("ruby " + @path_to_user + " init #{@private_key_A}")
    system ("ruby " + @path_to_robot + " init #{@private_key_B}")
  end

  def load_json_file(path)
    data_raw = File.read(path)
    data_json = JSON.parse(data_raw, symbolize_names: true)
    return data_json
  end

  def load_type()
    # type of asset.
    data_json = load_json_file(@path_to_file + "contract_info.json")
    type_script_json = data_json[:type_script]
    type_script_h = JSON.parse(type_script_json, symbolize_names: true)
    type_script = CKB::Types::Script.from_h(type_script_h)
    type_script_hash = type_script.compute_hash
    return type_script_hash
  end

  def load_type_dep()
    data_json = load_json_file(@path_to_file + "contract_info.json")
    udt_tx_hash = data_json[:udt_tx_hash]
    udt_dep = CKB::Types::CellDep.new(out_point: CKB::Types::OutPoint.new(tx_hash: udt_tx_hash, index: 0))
    return udt_dep
  end

  def create_commands_file(commands)
    file = File.new(@path_to_file + "commands.json", "w")
    file.syswrite(commands.to_json)
    file.close()
  end

  def update_command(key, value)
    commands_raw = File.read(@path_to_file + "commands.json")
    commands = JSON.parse(commands_raw, symbolize_names: true)
    commands[key] = value
    create_commands_file(commands)
  end

  def assert_db_filed_A(id, field, value)
    value_check = @coll_session_A.find({ id: id }).first[field]
    assert_equal(value_check, value, "#{field} wrong.")
  end

  def assert_db_filed_B(id, field, value)
    value_check = @coll_session_B.find({ id: id }).first[field]
    assert_equal(value_check, value, "#{field} wrong.")
  end

  def get_account_balance_ckb()
    # locks
    lock_hashes_A = [@default_lock_A.compute_hash]
    lock_hashes_B = [@default_lock_B.compute_hash]

    # balance.
    balance_current_A = get_balance(lock_hashes_A)
    balance_current_B = get_balance(lock_hashes_B)
    return [balance_current_A, balance_current_B]
  end

  def get_account_balance_udt()
    type_script_hash = load_type()
    type_info = find_type(type_script_hash)
    # locks
    lock_hashes_A = [@default_lock_A.compute_hash]
    lock_hashes_B = [@default_lock_B.compute_hash]

    # balance.
    balance_current_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
    balance_current_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])
    return [balance_current_A, balance_current_B]
  end

  # Test different invest of CKB.
  def check_investment_fee(investment_A, investment_B, fee_A, fee_B, expect, flag)
    begin
      init_client()
      @monitor_A, @monitor_B, @listener_A, @listener_B = start_listen_monitor()
      # UDT type
      type_script_hash = load_type()
      type_info = find_type(type_script_hash)

      # locks
      lock_hashes_A = [@default_lock_A.compute_hash]
      lock_hashes_B = [@default_lock_B.compute_hash]

      # balance.
      if flag == "ckb"
        balance_begin_A = get_balance(lock_hashes_A)
        balance_begin_B = get_balance(lock_hashes_B)
      elsif flag == "udt"
        balance_begin_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
        balance_begin_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])
      end

      # prepare the funding info.
      funding_A = investment_A
      funding_B = investment_B
      since = "9223372036854775908"

      commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
                   recv_fund_fee: fee_B, sender_one_way_permission: "yes",
                   payment_reply: "yes", closing_reply: "yes" }
      create_commands_file(commands)
      send_establishment_request_A(funding_A, fee_A, since, flag)

      return @monitor_A, @monitor_B
    rescue Exception => e
      raise e
    ensure
    end
  end

  def create_channel(funding_A, funding_B, container_min, fee_A_fund, fee_B_fund, success)
    begin
      @monitor_A, @monitor_B, @listener_A, @listener_B = start_listen_monitor()

      # load the udt type.
      type_script_hash = load_type()
      type_info = find_type(type_script_hash)

      # locks
      lock_hashes_A = [@default_lock_A.compute_hash]
      lock_hashes_B = [@default_lock_B.compute_hash]

      # balance.
      udt_A_begin, udt_B_begin = get_account_balance_udt()
      ckb_A_begin, ckb_B_begin = get_account_balance_ckb()

      @logger.info("gpctest.rb: A'udt before funding in udt channel: #{udt_A_begin}")
      @logger.info("gpctest.rb: B'udt before funding in udt channel: #{udt_B_begin}")
      @logger.info("gpctest.rb: A'ckb before funding in udt channel: #{ckb_A_begin}")
      @logger.info("gpctest.rb: B'ckb before funding in udt channel: #{ckb_B_begin}")

      since = "9223372036854775908"

      commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
                   recv_fund_fee: fee_B_fund, one_way_channel_permission: "yes",
                   payment_reply: "yes", closing_reply: "yes" }

      create_commands_file(commands)
      send_establishment_request_A(funding_A, fee_A_fund, since)
      if success
        # make the tx on chain.
        generate_blocks(@rpc, 10, 0.5)

        ckb_A_after_funding, ckb_B_after_funding = get_account_balance_ckb()
        udt_A_after_funding, udt_B_after_funding = get_account_balance_udt()

        @logger.info("gpctest.rb: A'udt after funding in udt channel: #{udt_A_after_funding}")
        @logger.info("gpctest.rb: B'udt after funding in udt channel: #{udt_B_after_funding}")
        @logger.info("gpctest.rb: A'ckb after funding in udt channel: #{ckb_A_after_funding}")
        @logger.info("gpctest.rb: B'ckb after funding in udt channel: #{ckb_B_after_funding}")

        # assert the balance after funding on chain.
        assert_equal(funding_A[:udt], udt_A_begin - udt_A_after_funding, "A'udt after funding is wrong.")
        assert_equal(funding_B[:udt], udt_B_begin - udt_B_after_funding, "B'udt after funding is wrong.")

        assert_equal(container_min + fee_A_fund + funding_A[:ckb] * 10 ** 8, ckb_A_begin - ckb_A_after_funding, "A'ckb after funding is wrong.")
        assert_equal(container_min + fee_B_fund + funding_B[:ckb] * 10 ** 8, ckb_B_begin - ckb_B_after_funding, "B'ckb after funding is wrong.")

        channel_id = @coll_session_A.find({ remote_pubkey: @secp_args_B }).first[:id]

        # assert the nounce and the stage?
        assert_db_filed_A(channel_id, :nounce, 1)
        assert_db_filed_A(channel_id, :stage, 1)
        assert_db_filed_B(channel_id, :nounce, 1)
        assert_db_filed_B(channel_id, :stage, 1)
      end
      return channel_id, @monitor_A, @monitor_B
    rescue Exception => e
      raise e
    end
  end

  # # A and B invest 20 UDT respectively.
  # def create_udt_channel(funding_A, funding_B, asset_type)
  #   begin
  #     init_client()
  #     container_min = 134 * 10 ** 8
  #     @monitor_A, @monitor_B, @listener_A, @listener_B = start_listen_monitor()
  #     # load the asset...
  #     type_script_hash = load_type()
  #     type_info = find_type(type_script_hash)

  #     # locks
  #     lock_hashes_A = [@default_lock_A.compute_hash]
  #     lock_hashes_B = [@default_lock_B.compute_hash]

  #     # balance.
  #     balance_begin_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
  #     balance_begin_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])

  #     capacity_begin_A = get_balance(lock_hashes_A)
  #     capacity_begin_B = get_balance(lock_hashes_B)

  #     @logger.info("A'balance before funding in udt channel: #{balance_begin_A}")
  #     @logger.info("B'balance before funding in udt channel: #{balance_begin_B}")

  #     # prepare the funding info.
  #     since = "9223372036854775908"

  #     commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
  #                  recv_fund_fee: fee_B_fund, recv_settle_fee: fee_receiver_settle, sender_one_way_permission: "yes",
  #                  payment_reply: "yes", closing_reply: "yes" }
  #     create_commands_file(commands)
  #     send_establishment_request_A(funding_A, fee_A_fund, since, "udt")

  #     # make the tx on chain.
  #     generate_blocks(@rpc, 10, 0.5)

  #     balance_after_funding_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
  #     balance_after_funding_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])

  #     capacity_after_funding_A = get_balance(lock_hashes_A)
  #     capacity_after_funding_B = get_balance(lock_hashes_B)

  #     @logger.info("A'balance after_funding in udt channel: #{balance_after_funding_A}")
  #     @logger.info("B'balance after_funding in udt channel: #{balance_after_funding_B}")
  #     # assert the balance after funding on chain.
  #     assert_equal(funding_A, balance_begin_A - balance_after_funding_A, "A'balance after funding is wrong.")
  #     assert_equal(funding_B, balance_begin_B - balance_after_funding_B, "B'balance after funding is wrong.")

  #     assert_equal(container_min + fee_A_fund, capacity_begin_A - capacity_after_funding_A, "A'capacity after funding is wrong.")
  #     assert_equal(container_min + fee_B_fund, capacity_begin_B - capacity_after_funding_B, "B'capacity after funding is wrong.")

  #     channel_id = @coll_session_A.find({ remote_pubkey: @secp_args_B }).first[:id]

  #     # assert the nounce and the stage?
  #     assert_db_filed_A(channel_id, :nounce, 1)
  #     assert_db_filed_A(channel_id, :stage, 1)
  #     assert_db_filed_B(channel_id, :nounce, 1)
  #     assert_db_filed_B(channel_id, :stage, 1)
  #     return channel_id, @monitor_A, @monitor_B
  #   rescue Exception => e
  #     raise e
  #   end
  # end

  # def create_ckb_channel(funding_A, funding_B, fee_A_fund = 4000, fee_B_fund = 2000, fee_receiver_settle = 1000)
  #   begin
  #     init_client()
  #     @monitor_A, @monitor_B, @listener_A, @listener_B = start_listen_monitor()
  #     container_min = 61 * 10 ** 8
  #     # lock
  #     lock_hashes_A = [@default_lock_A.compute_hash]
  #     lock_hashes_B = [@default_lock_B.compute_hash]

  #     # balance.
  #     balance_begin_A = get_balance(lock_hashes_A)
  #     balance_begin_B = get_balance(lock_hashes_B)

  #     # prepare the funding info.
  #     since = "9223372036854775908"

  #     commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
  #                  recv_fund_fee: fee_B_fund, recv_settle_fee: fee_receiver_settle, sender_one_way_permission: "yes",
  #                  payment_reply: "yes", closing_reply: "yes" }

  #     create_commands_file(commands)
  #     send_establishment_request_A(funding_A, fee_A_fund, since, "ckb")

  #     # make the tx on chain.
  #     generate_blocks(@rpc, 5, 0.5)

  #     balance_after_funding_A = get_balance(lock_hashes_A)
  #     balance_after_funding_B = get_balance(lock_hashes_B)

  #     # assert the balance after funding are right.
  #     assert_equal(funding_A * 10 ** 8 + container_min + fee_A_fund, balance_begin_A - balance_after_funding_A, "balance after funding is wrong.")
  #     assert_equal(funding_B * 10 ** 8 + container_min + fee_B_fund, balance_begin_B - balance_after_funding_B, "balance after funding is wrong.")

  #     channel_id = @coll_session_A.find({ remote_pubkey: @secp_args_B }).first[:id]

  #     # assert the nounce and the stage?
  #     assert_db_filed_A(channel_id, :nounce, 1)
  #     assert_db_filed_A(channel_id, :stage, 1)
  #     assert_db_filed_B(channel_id, :nounce, 1)
  #     assert_db_filed_B(channel_id, :stage, 1)
  #     return channel_id, @monitor_A, @monitor_B
  #   rescue Exception => e
  #     raise e
  #   end
  # end

  def send_tg_msg_A_B(channel_id, payment_type)
    system("ruby " + @path_to_user + " send_tg_msg --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --id #{channel_id}")
  end

  def make_payment_A_B(channel_id, payment_type, amount)
    system("ruby " + @path_to_user + " make_payment --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --id #{channel_id} --payment #{payment_type}:#{amount}")
  end

  def make_payment_B_A(channel_id, payment_type, amount)
    system("ruby " + @path_to_robot + " make_payment --pubkey #{@pubkey_B} --ip #{@ip_A} --port #{@listen_port_A} --id #{channel_id} --payment #{payment_type}:#{amount}")
  end

  # def make_payment_ckb_A_B(channel_id, amount)
  #   system("ruby " + @path_to_gpc + " make_payment --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --amount #{amount} --id #{channel_id}")
  # end

  # def make_payment_ckb_B_A(channel_id, amount)
  #   system("ruby " + @path_to_gpc + " make_payment --pubkey #{@pubkey_B} --ip #{@ip_A} --port #{@listen_port_A} --amount #{amount} --id #{channel_id}")
  # end

  def closing_A_B(channel_id, fee_sender, fee_receiver, closing_type)
    if closing_type == "bilateral"
      update_command(:closing_reply, "yes")
    elsif closing_type == "unilateral"
      update_command(:closing_reply, "no")
    end

    update_command(:recv_settle_fee, fee_receiver)

    system("ruby " + @path_to_user + " send_closing_request --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --id #{channel_id} --fee #{fee_sender}")
    # give time for closing tx.
    generate_blocks(@rpc, 30)
    generate_blocks(@rpc, 5, 1)
    # give time for settlement tx.
    generate_blocks(@rpc, 200)
    generate_blocks(@rpc, 5, 1)
  end

  def closing_B_A(channel_id, fee_sender, fee_receiver, fee_uni_closing, fee_uni_settle, closing_type)
    if closing_type == "bilateral"
      update_command(:closing_reply, "yes")
    elsif closing_type == "unilateral"
      update_command(:closing_reply, "no")
    else
      return false
    end
    update_command(:recv_settle_fee, fee_receiver)
    update_command(:closing_fee_unilateral, fee_uni_closing)
    update_command(:settle_fee_unilateral, fee_uni_settle)

    system("ruby " + @path_to_robot + " send_closing_request --pubkey #{@pubkey_B} --ip #{@ip_A} --port #{@listen_port_A} --id #{channel_id} --fee #{fee_sender}")
    # give time for closing tx.
    generate_blocks(@rpc, 30)
    generate_blocks(@rpc, 5, 1)
    # give time for settlement tx.
    generate_blocks(@rpc, 200)
    generate_blocks(@rpc, 5, 1)
  end
end
