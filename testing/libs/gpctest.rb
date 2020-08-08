require "rubygems"
require "bundler/setup"
require "minitest/autorun"
require "mongo"
require "json"
require "ckb"
require "./libs/types.rb"

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

$VERBOSE = nil

class Gpctest < Minitest::Test
  def initialize(name)
    super(name)
    @privkey = "0xd00c06bfd800d27397002dca6fb0993d5ba6399b4238b2f29ee9deb97593d2bc"
    @api = CKB::API::new
    @rpc = CKB::RPC.new
    @wallet = CKB::Wallet.from_hex(@api, @privkey)

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
    # preparation_before_test()
  end

  def preparation_before_test()
    setup()
  end

  def generate_blocks(rpc, num, interval = 0)
    for i in 0..num
      rpc.generate_block
      sleep(interval)
    end
    return true
  end

  def deploy_contract(data)
    code_hash = CKB::Blake2b.hexdigest(data)
    data_size = data.bytesize
    tx_hash = @wallet.send_capacity(@wallet.address, CKB::Utils.byte_to_shannon(data_size + 10000), CKB::Utils.bin_to_hex(data), fee: 10 ** 6)
    return [code_hash, tx_hash]
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
    gpc_data = File.read("./binary/gpc")
    gpc_code_hash, gpc_tx_hash = deploy_contract(gpc_data)
    generate_blocks(@rpc, 5)

    # send udt contract to the chain.
    udt_data = File.read("./binary/simple_udt")
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
      tx = @wallet.generate_tx(@wallet.address, CKB::Utils.byte_to_shannon(2000), fee: 1000)
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
      first_output.capacity /= 2
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

      signed_tx = tx.sign(@wallet.key)
      root_udt_tx_hash = @api.send_transaction(signed_tx)
      generate_blocks(@rpc, 5)
    end

    # record these info to json. So the gpc client can read them.
    script_info = { gpc_code_hash: gpc_code_hash, gpc_tx_hash: gpc_tx_hash,
                    udt_code_hash: udt_code_hash, udt_tx_hash: udt_tx_hash,
                    type_script: type_script.to_h.to_json }
    file = File.new("./files/contract_info.json", "w")
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
          next if type_script_hash_current != type_script_hash
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
    monitor_A = spawn("ruby -W0 ../client1/GPC monitor #{@pubkey_A}")
    monitor_B = spawn("ruby -W0 ../client1/GPC monitor #{@pubkey_B}")
    listener_A = spawn("ruby -W0 ../client1/GPC listen #{@pubkey_A} #{@listen_port_A}")
    listener_B = spawn("ruby -W0 ../client1/GPC listen #{@pubkey_B} #{@listen_port_B}")
    return monitor_A, monitor_B, listener_A, listener_B
  end

  def close_all_thread(monitor_A, monitor_B, db)
    system("kill #{monitor_A}")
    system("kill #{monitor_B}")
    system("npx kill-port 1000")
    system("npx kill-port 2000")
    db.drop()
  end

  def init_client()
    system ("ruby -W0 ../client1/GPC init #{@private_key_A}")
    system ("ruby -W0 ../client1/GPC init #{@private_key_B}")
  end

  def load_json_file(path)
    data_raw = File.read(path)
    data_json = JSON.parse(data_raw, symbolize_names: true)
    return data_json
  end

  def load_type()
    # type of asset.
    data_json = load_json_file("./files/contract_info.json")
    type_script_json = data_json[:type_script]
    type_script_h = JSON.parse(type_script_json, symbolize_names: true)
    type_script = CKB::Types::Script.from_h(type_script_h)
    type_script_hash = type_script.compute_hash
    return type_script_hash
  end

  def create_commands_file(commands)
    file = File.new("./files/commands.json", "w")
    file.syswrite(commands.to_json)
    file.close()
  end

  def assert_db_filed(collection, id, filed, value)
    value_check = collection.find({ id: id }).first[filed]
    assert_equal(value_check, value, "#{filed} wrong.")
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

  # A and B invest all their UDT.
  # A pays B 10 UDT.
  # A request close the channel, but B refuses.
  def test1()
    begin
      preparation_before_test()

      # load the asset...
      type_script_hash = load_type()
      type_info = find_type(type_script_hash)

      # locks
      lock_hashes_A = [@default_lock_A.compute_hash]
      lock_hashes_B = [@default_lock_B.compute_hash]

      # balance.
      balance_begin_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
      balance_begin_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])

      # prepare the funding info.
      fee_A = 4000
      fee_B = 2000
      funding_A = balance_begin_A
      funding_B = balance_begin_B
      since = "9223372036854775908"

      commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
                   recv_fee: fee_B, sender_one_way_permission: "yes",
                   payment_reply: "yes", closing_reply: "no" }
      create_commands_file(commands)

      sender_A = spawn("ruby -W0 ../client1/GPC send_establishment_request --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --amount #{funding_A} --fee #{fee_A} --since #{since} --type_script_hash #{type_script_hash}")
      Process.wait sender_A

      # make the tx on chain.
      generate_blocks(@rpc, 5, 0.5)

      balance_after_funding_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
      balance_after_funding_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])

      # assert the balance after funding on chain.
      assert_equal(funding_A, balance_begin_A - balance_after_funding_A, "balance after funding is wrong.")
      assert_equal(funding_B, balance_begin_B - balance_after_funding_B, "balance after funding is wrong.")

      channel_id = @coll_session_A.find({ remote_pubkey: @secp_args_B }).first[:id]

      # assert the nounce and the stage?
      assert_db_filed(@coll_session_A, channel_id, :nounce, 1)
      assert_db_filed(@coll_session_A, channel_id, :stage, 1)
      assert_db_filed(@coll_session_B, channel_id, :nounce, 1)
      assert_db_filed(@coll_session_B, channel_id, :stage, 1)

      payment_A_to_B_10 = spawn("ruby -W0 ../client1/GPC make_payment --pubkey #{@pubkey_A} --ip #{@ip_A} --port #{@listen_port_B} --amount 10 --id #{channel_id} --type_script_hash #{type_script_hash}")
      Process.wait payment_A_to_B_10

      # closing
      closing_A_to_B = spawn("ruby -W0 ../client1/GPC send_closing_request --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --id #{channel_id}")
      Process.wait closing_A_to_B

      # give time for closing tx.
      generate_blocks(@rpc, 5, 1)
      generate_blocks(@rpc, 200)
      # give time for settlement tx.
      generate_blocks(@rpc, 5, 1)

      balance_refunding_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
      balance_refunding_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])
      assert_equal(-10, balance_begin_A - balance_refunding_A, "refunding not right")
      assert_equal(10, balance_begin_B - balance_refunding_B, "refunding not right")
    rescue Exception => e
      raise e
    ensure
      close_all_thread(@monitor_A, @monitor_B, @db)
    end
    # delete databases

  end

  # Test different invest of CKB.
  def check_investment_fee(investment_A, investment_B, fee_A, fee_B, record_type, flag)
    begin
      init_client()
      @monitor_A, @monitor_B, @listener_A, @listener_B = start_listen_monitor()

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
                   recv_fee: fee_B, sender_one_way_permission: "yes",
                   payment_reply: "yes", closing_reply: "yes" }
      create_commands_file(commands)

      sender_A = flag == "ckb" ? spawn("ruby -W0 ../client1/GPC send_establishment_request --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --amount #{funding_A} --fee #{fee_A} --since #{since}") : spawn("ruby -W0 ../client1/GPC make_payment --pubkey #{@pubkey_A} --ip #{@ip_A} --port #{@listen_port_B} --amount 10 --id #{channel_id} --type_script_hash #{type_script_hash}")
      Process.wait sender_A

      if "#{record_type}".include? "error"
        error_json = load_json_file("./files/errors.json")
        puts assert_equal(1, error_json[record_type], "#{record_type}")
      else
        success_json = load_json_file("./files/successes.json")
        puts assert_equal(1, success_json[record_type], "#{record_type}")
      end
    rescue Exception => e
      raise e
    ensure
      close_all_thread(@monitor_A, @monitor_B, @db)
    end
  end

  # B wants to invest the UDT beyond he can afford.
  # Test different invest of UDT.
  def test3()
    begin
      # load the asset...
      type_script_hash = load_type()
      type_info = find_type(type_script_hash)

      # locks
      lock_hashes_A = [@default_lock_A.compute_hash]
      lock_hashes_B = [@default_lock_B.compute_hash]

      # balance.
      balance_begin_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
      balance_begin_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])

      # prepare the funding info.
      fee_A = 4000
      fee_B = 2000
      funding_A = balance_begin_A
      funding_B = balance_begin_B + 1
      since = "9223372036854775908"

      commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
                   recv_fee: fee_B, sender_one_way_permission: "yes",
                   payment_reply: "yes", closing_reply: "no" }
      create_commands_file(commands)

      sender_A = spawn("ruby -W0 ../client1/GPC send_establishment_request --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --amount #{funding_A} --fee #{fee_A} --since #{since} --type_script_hash #{type_script_hash}")
      Process.wait sender_A

      error_json = load_json_file("./files/errors.json")
      assert_equal(1, error_json[:recv_fund_insufficient], "Insufficient check failed")
    rescue Exception => e
      raise e
    ensure
      close_all_thread(@monitor_A, @monitor_B, @db)
    end
    # delete databases

  end

  # A and B invest all their UDT.
  # A try to pay the money he can not afford.
  def test4()
    begin
      # load the asset...
      type_script_hash = load_type()
      type_info = find_type(type_script_hash)

      # locks
      lock_hashes_A = [@default_lock_A.compute_hash]
      lock_hashes_B = [@default_lock_B.compute_hash]

      # balance.
      balance_begin_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
      balance_begin_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])

      # prepare the funding info.
      fee_A = 4000
      fee_B = 2000
      funding_A = balance_begin_A
      funding_B = balance_begin_B
      since = "9223372036854775908"

      commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
                   recv_fee: fee_B, sender_one_way_permission: "yes",
                   payment_reply: "yes", closing_reply: "no" }
      create_commands_file(commands)

      sender_A = spawn("ruby -W0 ../client1/GPC send_establishment_request --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --amount #{funding_A} --fee #{fee_A} --since #{since} --type_script_hash #{type_script_hash}")
      Process.wait sender_A

      # make the tx on chain.
      generate_blocks(@rpc, 5, 0.5)

      balance_after_funding_A = get_balance(lock_hashes_A, type_script_hash, type_info[:decoder])
      balance_after_funding_B = get_balance(lock_hashes_B, type_script_hash, type_info[:decoder])

      # assert the balance after funding are right.
      assert_equal(funding_A, balance_begin_A - balance_after_funding_A, "balance after funding is wrong.")
      assert_equal(funding_B, balance_begin_B - balance_after_funding_B, "balance after funding is wrong.")

      channel_id = @coll_session_A.find({ remote_pubkey: @secp_args_B }).first[:id]
      payment_A_to_B = spawn("ruby -W0 ../client1/GPC make_payment --pubkey #{@pubkey_A} --ip #{@ip_A} --port #{@listen_port_B} --amount #{funding_A + 1} --id #{channel_id} --type_script_hash #{type_script_hash}")
      Process.wait payment_A_to_B

      error_json = load_json_file("./files/errors.json")
      assert_equal(1, error_json[:Insufficient_amount_to_pay], "Insufficient check failed")
    rescue Exception => e
      raise e
    ensure
      close_all_thread(@monitor_A, @monitor_B, @db)
    end
    # delete databases

  end

  # A and B invest all their ckb.
  # A try to pay the ckb.
  def test5()
    begin
      # locks
      lock_hashes_A = [@default_lock_A.compute_hash]
      lock_hashes_B = [@default_lock_B.compute_hash]

      # balance.
      balance_begin_A = get_balance(lock_hashes_A)
      balance_begin_B = get_balance(lock_hashes_B)

      # prepare the funding info.
      fee_A = 4000
      fee_B = 2000
      funding_A = 1000
      funding_B = 2000
      since = "9223372036854775908"

      commands = { sender_reply: "yes", recv_reply: "yes", recv_fund: funding_B,
                   recv_fee: fee_B, sender_one_way_permission: "yes",
                   payment_reply: "yes", closing_reply: "no" }
      create_commands_file(commands)

      sender_A = spawn("ruby -W0 ../client1/GPC send_establishment_request --pubkey #{@pubkey_A} --ip #{@ip_B} --port #{@listen_port_B} --amount #{funding_A} --fee #{fee_A} --since #{since}")
      Process.wait sender_A

      # make the tx on chain.
      generate_blocks(@rpc, 5, 0.5)

      balance_after_funding_A = get_balance(lock_hashes_A)
      balance_after_funding_B = get_balance(lock_hashes_B)

      # assert the balance after funding are right.
      assert_equal(funding_A, balance_begin_A - balance_after_funding_A, "balance after funding is wrong.")
      assert_equal(funding_B, balance_begin_B - balance_after_funding_B, "balance after funding is wrong.")

      channel_id = @coll_session_A.find({ remote_pubkey: @secp_args_B }).first[:id]
      # payment_A_to_B = spawn("ruby -W0 ../client1/GPC make_payment --pubkey #{@pubkey_A} --ip #{@ip_A} --port #{@listen_port_B} --amount #{funding_A + 1} --id #{channel_id}")
      # Process.wait payment_A_to_B
    rescue Exception => e
      raise e
    ensure
      close_all_thread(@monitor_A, @monitor_B, @db)
    end
    # delete databases

  end
end