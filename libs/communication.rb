#!/usr/bin/ruby -w

require "socket"
require "json"
require "rubygems"
require "bundler/setup"
require "ckb"
require "digest/sha1"
require "mongo"
require "../libs/tx_generator.rb"
require "../libs/mongodb_operate.rb"
require "../libs/mongodb_operate.rb"
require "../libs/ckb_interaction.rb"
require "../libs/verification.rb"

Mongo::Logger.logger.level = Logger::FATAL

class Communication
  def initialize(private_key)
    @key = CKB::Key.new(private_key)
    @api = CKB::API::new
    @wallet = CKB::Wallet.from_hex(@api, @key.privkey)
    @tx_generator = Tx_generator.new(@key)
    @client = Mongo::Client.new(["127.0.0.1:27017"], :database => "GPC")
    @db = @client.database
    @coll_sessions = @db[@key.pubkey + "_session_pool"]
    @gpc_code_hash = "0xf3bdd1340f8db1fa67c3e87dad9ee9fe39b3cecc5afcfb380805245184bbc36f"
    @gpc_tx = "0x411d9b0b468d650cb0a577b3d93a18eac6ccff7b7515c41bd59b906606981568"
    @steady_stage = []
  end

  def generate_text_msg(text)
    return { type: 0, text: text }.to_json
  end

  # These two functions are used to parse-construct ctx_info and stx_info.
  def info_to_json(info)
    info_h = info
    info_h[:outputs] = info[:outputs].map(&:to_h)
    info_json = info_h.to_json
    return info_json
  end

  def json_to_info(json)
    info_h = JSON.parse(json, symbolize_names: true)
    info = info_h
    info[:outputs] = info_h[:outputs].map { |output| CKB::Types::Output.from_h(output) }
    return info
  end

  def process_recv_message(client, msg, command_file)
    type = msg[:type]
    view = @coll_sessions.find({ id: msg[:id] })
    if view.count_documents() == 0 && type != 1
      msg_reply = generate_text_msg("sry, the msg's type is inconsistent with the type in local database!")
      client.puts (msg_reply)
      return -1
    elsif view.count_documents() == 1
      view.each do |doc|
        if doc["status"] != type
          msg_reply = generate_text_msg("sry, the msg's type is inconsistent with the type in local database!")
          client.puts (msg_reply)
          return -1
        end
      end
    elsif view.count_documents() > 1
      msg_reply = generate_text_msg("sry, there are more than one record about the id.")
      client.puts (msg_reply)
      return -1
    end

    case type

    # when -2 # Reset the status.
    #   recover_stage = msg[:recover_stage]

    #   # case 1: revert to the establishment stage.

    #   # case 2: revert to the
    #   local_stage < 6
    #   # get the nearest camp.

    when -1
      msg_reply_json = @coll_sessions.find({ id: msg[:id] }).first[:msg_cache]
      msg_reply = JSON.parse(client.gets, symbolize_names: true)
      client.puts (msg_reply)
      return 0
    when 0 # Just the plain text.
      puts msg[:text]
      return 0
    when 1

      # parse the msg
      remote_pubkey = msg[:pubkey]
      remote_capacity = msg[:fund_capacity]
      remote_fee = msg[:fee]
      remote_fund_cells = msg[:fund_cells].map { |cell| CKB::Types::Input.from_h(cell) }
      timeout = msg[:timeout]

      # the type_script is nil in CKByte
      type_script = nil

      # check the cell is live and the capacity is enough.
      capacity_check = check_cells(remote_fund_cells,
                                   CKB::Utils.byte_to_shannon(remote_capacity) + remote_fee)
      if capacity_check == -1
        client.puts(generate_text_msg("sry, your capacity is not enough or your cells are not alive."))
        return -1
      end

      # calcualte the remote change.
      remote_change = capacity_check - CKB::Utils.byte_to_shannon(remote_capacity) - remote_fee

      # Ask whether willing to accept the request, the capacity is same as negotiations.
      puts "The remote capacity: #{remote_capacity}. The remote fee:#{remote_fee}"
      puts "Tell me whether you are willing to accept this request"

      # It should be more robust.
      while true
        response = command_file.gets.gsub("\n", "")
        if response == "yes"
          break
        elsif response == "no"
          puts "reject it "
          return -1
        else
          puts "your input is invalid"
        end
      end

      # Get the capacity and fee. These code need to be more robust.
      while true
        puts "Please input the capacity and fee you want to use for funding"
        local_capacity = command_file.gets.gsub("\n", "").to_i
        local_fee = command_file.gets.gsub("\n", "").to_i
        break
      end

      # gather the fund inputs.
      local_fund_cells = gather_inputs(local_capacity, local_fee)
      local_fund_cells_h = local_fund_cells.inputs.map(&:to_h)
      local_change = local_fund_cells.capacities -
                     CKB::Utils.byte_to_shannon(local_capacity) - local_fee

      # generate the info of fund.
      gpc_capacity = remote_capacity + local_capacity
      fund_cells = remote_fund_cells + local_fund_cells.inputs
      fund_witnesses = Array.new()
      for iter in fund_cells
        fund_witnesses << CKB::Types::Witness.new       # the witness will be customized in UDT.
      end

      # Let us create the fund tx!
      fund_tx = @tx_generator.generate_fund_tx(fund_cells, gpc_capacity, local_change, remote_change,
                                               remote_pubkey, timeout, type_script, fund_witnesses)

      # send it
      msg_reply = { id: msg[:id], type: 2, fee: local_fee, fund_tx: fund_tx.to_h,
                    capacity: local_capacity }.to_json
      client.puts(msg_reply)

      # update database.
      doc = { id: msg[:id], local_pubkey: CKB::Key.blake160(@key.pubkey), remote_pubkey: remote_pubkey,
              status: 3, nounce: 0, ctx: 0, stx: 0, gpc_script: CKB::Serializers::ScriptSerializer.new(fund_tx.outputs[0].lock).serialize,
              local_fund_cells: local_fund_cells_h, fund_tx: fund_tx.to_h, msg_cache: msg_reply, local_capacity: local_capacity }
      ret = insert_with_check(@coll_sessions, doc)
      return -1 if ret == -1

      return 0
    when 2

      # parse the msg.
      fund_tx = CKB::Types::Transaction.from_h(msg[:fund_tx])
      remote_capacity = msg[:capacity]
      remote_fee = msg[:fee]
      local_fund_cells = @coll_sessions.find({ id: msg[:id] }).first[:local_fund_cells]
      local_fund_cells = local_fund_cells.map { |cell| JSON.parse(cell.to_json, symbolize_names: true) }
      remote_fund_cells = fund_tx.inputs.map(&:to_h) - local_fund_cells
      remote_fund_cells = remote_fund_cells.map { |cell| CKB::Types::Input.from_h(cell) }
      local_pubkey = @coll_sessions.find({ id: msg[:id] }).first[:local_pubkey]
      local_capacity = @coll_sessions.find({ id: msg[:id] }).first[:local_capacity]
      local_fee = @coll_sessions.find({ id: msg[:id] }).first[:local_fee]
      timeout = @coll_sessions.find({ id: msg[:id] }).first[:timeout]

      # get the remote pubkey (blake160). Assumption, there are only two pubkey.
      input_group = @tx_generator.group_tx_input(fund_tx)
      for key in input_group.keys
        if key != CKB::Key.blake160(@key.pubkey)
          remote_pubkey = key
        end
      end

      # compute the gpc script by myself, and check it. So here, we can make sure that the GPC args are right.
      init_args = @tx_generator.generate_lock_args(0, timeout, 0, local_pubkey[2..-1], remote_pubkey[2..-1])
      gpc_lock_script = CKB::Types::Script.new(code_hash: @gpc_code_hash, args: init_args, hash_type: CKB::ScriptHashType::DATA)
      if CKB::Serializers::ScriptSerializer.new(fund_tx.outputs[0].lock).serialize != CKB::Serializers::ScriptSerializer.new(gpc_lock_script).serialize
        client.puts(generate_text_msg("sry, the gpc lock is inconsistent with my verison."))
        return -1
      end

      # check the cells are alive and the capacity is enough.
      capacity_check = check_cells(remote_fund_cells, CKB::Utils.byte_to_shannon(remote_capacity) + remote_fee)
      if capacity_check == -1
        client.puts(generate_text_msg("sry, your capacity is not enough or your cells are not alive."))
        return -1
      end

      # check change is right!

      local_fund_cells = local_fund_cells.map { |cell| CKB::Types::Input.from_h(cell) }
      verify_result = verify_change(fund_tx, local_fund_cells, local_capacity,
                                    local_fee, CKB::Key.blake160(@key.pubkey))
      if capacity_check == -1
        client.puts(generate_text_msg("sry, my change has problem"))
        return -1
      end
      verify_result = verify_change(fund_tx, remote_fund_cells, remote_capacity,
                                    remote_fee, remote_pubkey)
      if capacity_check == -1
        client.puts(generate_text_msg("sry, your change has problem"))
        return -1
      end

      # check gpc capacity is right!
      total_fund_capacity = local_capacity + remote_capacity
      if CKB::Utils.byte_to_shannon(total_fund_capacity) != fund_tx.outputs[0].capacity
        client.puts(generate_text_msg("sry, the gpc_capacity has problem"))
        return -1
      end

      #-------------------------------------------------
      # just verify the other part (version, deps, )
      # verify_result = verify_tx(fund_tx)
      # if verify_result == -1
      #   client.puts(generate_text_msg("sry, the fund tx has some problem..."))
      #   return -1
      # end

      # check the remote capcity is satisfactory.
      puts "remote capacity #{remote_capacity}, remote fee: #{remote_fee}"

      # generate the output locks in closing tx.
      init_args = fund_tx.outputs[0].lock.args
      lock_info = @tx_generator.parse_lock_args(init_args)
      lock_info[:nounce] += 1

      # generate the output locks in settlement tx.
      local_default_lock = CKB::Types::Script.new(code_hash: CKB::SystemCodeHash::SECP256K1_BLAKE160_SIGHASH_ALL_TYPE_HASH,
                                                  args: "0x" + lock_info[:pubkey_A], hash_type: CKB::ScriptHashType::TYPE)
      remote_default_lock = CKB::Types::Script.new(code_hash: CKB::SystemCodeHash::SECP256K1_BLAKE160_SIGHASH_ALL_TYPE_HASH,
                                                   args: "0x" + lock_info[:pubkey_B], hash_type: CKB::ScriptHashType::TYPE)

      # generate the output info in settlement tx.
      local = { capacity: CKB::Utils.byte_to_shannon(local_capacity), data: "0x", lock: local_default_lock }
      remote = { capacity: CKB::Utils.byte_to_shannon(remote_capacity), data: "0x", lock: remote_default_lock }

      closing_capacity = fund_tx.outputs[0].capacity

      input_type = ""
      output_type = ""
      closing_output_data = "0x"

      witness_closing = @tx_generator.generate_empty_witness(1, lock_info[:nounce], input_type, output_type)
      witness_settlement = @tx_generator.generate_empty_witness(0, lock_info[:nounce], input_type, output_type)

      # generate and sign ctx and stx.
      ctx_info = @tx_generator.generate_closing_info(lock_info, closing_capacity, closing_output_data, witness_closing, 0)
      stx_info = @tx_generator.generate_settlement_info(local, remote, witness_settlement, 0)

      ctx_info_json = info_to_json(ctx_info)
      stx_info_json = info_to_json(stx_info)

      # send the info
      msg_reply = { id: msg[:id], type: 3, ctx: ctx_info_json, stx: stx_info_json, capacity: local_capacity }.to_json
      client.puts(msg_reply)

      # update the database.w
      @coll_sessions.find_one_and_update({ id: msg[:id] }, { "$set" => { gpc_script: CKB::Serializers::ScriptSerializer.new(gpc_lock_script).serialize,
                                                                        remote_pubkey: remote_pubkey, fund_tx: msg[:fund_tx], ctx: ctx_info_json,
                                                                        stx: stx_info_json, status: 4, msg_cache: msg_reply } })

      return 0
    when 3
      fund_tx = @coll_sessions.find({ id: msg[:id] }).first[:fund_tx]
      fund_tx = CKB::Types::Transaction.from_h(fund_tx)
      local_capacity = @coll_sessions.find({ id: msg[:id] }).first[:local_capacity]
      remote_capacity = msg[:capacity]

      remote_ctx_info = json_to_info(msg[:ctx])
      remote_stx_info = json_to_info(msg[:stx])

      closing_output_data = "0x"

      # verify the signatures of ctx and stx.
      verify_result = verify_info(msg, 0)
      if verify_result != 0
        puts "The signatures are invalid."
        return -1
      end

      # sign the ctx and stx.

      # just check these information are same as the remote one.
      init_args = fund_tx.outputs[0].lock.args
      lock_info = @tx_generator.parse_lock_args(init_args)
      lock_info[:nounce] += 1

      local_default_lock = CKB::Types::Script.new(code_hash: CKB::SystemCodeHash::SECP256K1_BLAKE160_SIGHASH_ALL_TYPE_HASH,
                                                  args: "0x" + lock_info[:pubkey_B], hash_type: CKB::ScriptHashType::TYPE)
      remote_default_lock = CKB::Types::Script.new(code_hash: CKB::SystemCodeHash::SECP256K1_BLAKE160_SIGHASH_ALL_TYPE_HASH,
                                                   args: "0x" + lock_info[:pubkey_A], hash_type: CKB::ScriptHashType::TYPE)

      local = { capacity: CKB::Utils.byte_to_shannon(local_capacity),
                data: "0x", lock: local_default_lock }
      remote = { capacity: CKB::Utils.byte_to_shannon(remote_capacity),
                 data: "0x", lock: remote_default_lock }
      closing_capacity = fund_tx.outputs[0].capacity

      # check the outputs in stx are right.

      ctx_info = @tx_generator.generate_closing_info(lock_info, closing_capacity,
                                                     closing_output_data, remote_ctx_info[:witness], 1) # 0: output 1: output_data 2: witness
      stx_info = @tx_generator.generate_settlement_info(remote, local,
                                                        remote_stx_info[:witness], 1) # 0: output 1: output_data 2: witness

      ctx_info_json = info_to_json(ctx_info)
      stx_info_json = info_to_json(stx_info)

      # send the info
      msg_reply = { id: msg[:id], type: 4, ctx: ctx_info_json, stx: stx_info_json }.to_json
      client.puts(msg_reply)

      @coll_sessions.find_one_and_update({ id: msg[:id] }, { "$set" => { ctx: ctx_info_json,
                                                                        stx: stx_info_json, status: 5, msg_cache: msg_reply } })

      return 0
    when 4

      # check the data is not modified!
      local_ctx_info = json_to_info(@coll_sessions.find({ id: msg[:id] }).first[:ctx])
      local_stx_info = json_to_info(@coll_sessions.find({ id: msg[:id] }).first[:stx])

      remote_ctx_info = json_to_info(msg[:ctx])
      remote_stx_info = json_to_info(msg[:stx])

      local_ctx_sig = @tx_generator.parse_witness_lock(@tx_generator.parse_witness(local_ctx_info[:witness]).lock)[:sig_A]
      remote_ctx_sig = @tx_generator.parse_witness_lock(@tx_generator.parse_witness(remote_ctx_info[:witness]).lock)[:sig_A]

      local_stx_sig = @tx_generator.parse_witness_lock(@tx_generator.parse_witness(local_stx_info[:witness]).lock)[:sig_A]
      remote_stx_sig = @tx_generator.parse_witness_lock(@tx_generator.parse_witness(remote_stx_info[:witness]).lock)[:sig_A]

      verify_result = verify_info(msg, 0)
      if verify_result != 0 || local_ctx_sig != remote_ctx_sig || local_stx_sig != remote_stx_sig
        puts "The data is modified."
        return -1
      end

      # check the remote signature
      verify_result = verify_info(msg, 1)
      if verify_result != 0
        puts "The signatures are invalid."
        return -1
      end

      # sign and send the fund_tx
      fund_tx = @coll_sessions.find({ id: msg[:id] }).first[:fund_tx]
      fund_tx = CKB::Types::Transaction.from_h(fund_tx)

      fund_tx = @tx_generator.sign_tx(fund_tx).to_h

      msg_reply = { id: msg[:id], type: 5, fund_tx: fund_tx }.to_json
      client.puts(msg_reply)

      @coll_sessions.find_one_and_update({ id: msg[:id] }, { "$set" => { fund_tx: fund_tx,
                                                                        ctx: msg[:ctx], stx: msg[:stx], status: 6, msg_cache: msg_reply } })

      # update the database

      return 0
    when 5

      # just check the fund_tx is same as local except the witness

      # sign the fund_tx and send it to chain
      fund_tx_local = @coll_sessions.find({ id: msg[:id] }).first[:fund_tx]
      fund_tx_local = CKB::Types::Transaction.from_h(fund_tx_local)

      fund_tx_remote = msg[:fund_tx]
      fund_tx_remote = CKB::Types::Transaction.from_h(fund_tx_remote)

      fund_tx_local_hash = fund_tx_local.compute_hash
      fund_tx_remote_hash = fund_tx_remote.compute_hash

      if fund_tx_local_hash != fund_tx_remote_hash
        puts "fund tx is not consistent."
        return -1
      end

      fund_tx = @tx_generator.sign_tx(fund_tx_remote)

      # update the database
      @coll_sessions.find_one_and_update({ id: msg[:id] }, { "$set" => { fund_tx: fund_tx.to_h, status: 6 } })
      # @api.send_transaction(fund_tx)
      return 0
    when 6

      # just check the witness is valid.

      # add the local witness

      # update the database.
    when 7

      # just check the witness is valid.

      # add the local witness

      # send it to chain.
    end
  end

  def listen(src_port, command_file)
    puts "listen start"
    server = TCPServer.open(src_port)
    loop {
      Thread.start(server.accept) do |client|

        #parse the msg
        while (1)
          msg = JSON.parse(client.gets, symbolize_names: true)
          ret = process_recv_message(client, msg, command_file)
          break if ret == 100
        end
      end
    }
  end

  def send_establish_channel(remote_ip, remote_port, capacity, fee, timeout, command_file)
    s = TCPSocket.open(remote_ip, remote_port)

    # prepare the msg components.
    local_fund_cells = gather_inputs(capacity, fee)
    local_fund_cells = local_fund_cells.inputs.map(&:to_h)
    local_pubkey = CKB::Key.blake160(@key.pubkey)
    lock_timeout = timeout

    # get id.
    msg_digest = local_fund_cells.to_json
    session_id = Digest::MD5.hexdigest(msg_digest)
    msg = { id: session_id, type: 1, pubkey: local_pubkey, fund_cells: local_fund_cells,
            fund_capacity: capacity, fee: fee, timeout: lock_timeout }.to_json

    # send the msg.
    s.puts(msg)

    #insert the doc into database.
    doc = { id: session_id, local_pubkey: local_pubkey, remote_pubkey: "", status: 2,
            nounce: 0, ctx: 0, stx: 0, gpc_script: 0, local_fund_cells: local_fund_cells,
            timeout: lock_timeout, msg_cache: msg.to_json, local_capacity: capacity, local_fee: fee }
    ret = insert_with_check(@coll_sessions, doc)
    return -1 if ret == -1

    # just keep listen
    while (1)
      msg = JSON.parse(s.gets, symbolize_names: true)
      process_recv_message(s, msg, command_file)
    end
  end
end
