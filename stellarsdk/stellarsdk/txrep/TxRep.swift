//
//  File.swift
//  stellarsdk
//
//  Created by Christian Rogobete on 04.08.20.
//  Copyright © 2020 Soneso. All rights reserved.
//

import Foundation

public enum TxRepError: Error {
    case missingValue(key:String)
    case invalidValue(key:String)
}

public class TxRep: NSObject {
    
    public static func toTxRep(transactionEnvelope:String) throws ->String  {
        let xdrDecoder = XDRDecoder.init(data: [UInt8].init(base64: transactionEnvelope))
        let transactionEnvelopeXDR = try TransactionEnvelopeXDR(fromBinary: xdrDecoder)
        let transaction:Transaction = try Transaction(envelopeXdr: transactionEnvelope)
        var feeBumpTransaction:FeeBumpTransaction?
        var feeBumpSignatures = [DecoratedSignatureXDR]()
        switch transactionEnvelopeXDR {
        case .feeBump(let feeBumpXdr):
            let mux = try MuxedAccount(accountId: feeBumpXdr.tx.sourceAccount.accountId, sequenceNumber: 0, id: feeBumpXdr.tx.sourceAccount.id)
            feeBumpTransaction = try FeeBumpTransaction(sourceAccount: mux, fee: feeBumpXdr.tx.fee, innerTransaction: transaction)
            feeBumpSignatures = feeBumpXdr.signatures
        default:
            break;
        }
        let isFeeBump = feeBumpTransaction != nil
        var lines = [String]()
        let type = isFeeBump ? "ENVELOPE_TYPE_TX_FEE_BUMP" : "ENVELOPE_TYPE_TX";
        let prefix = isFeeBump ? "feeBump.tx.innerTx.tx." : "tx.";
        addLine(key: "type", value: type, lines: &lines);
        if let feeBump = feeBumpTransaction {
            addLine(key: "feeBump.tx.feeSource", value: feeBump.sourceAccountId, lines: &lines);
            addLine(key: "feeBump.tx.fee", value: String(feeBump.fee), lines: &lines);
            addLine(key: "feeBump.tx.innerTx.type", value: "ENVELOPE_TYPE_TX",lines: &lines);
        }
        addLine(key: prefix + "sourceAccount", value: transactionEnvelopeXDR.txSourceAccountId, lines: &lines)
        addLine(key: prefix + "fee", value: String(transactionEnvelopeXDR.txFee), lines: &lines)
        addLine(key: prefix + "seqNum", value: String(transactionEnvelopeXDR.txSeqNum), lines: &lines)
        addTimeBounds(timeBounds: transactionEnvelopeXDR.txTimeBounds, prefix: prefix, lines: &lines)
        try addMemo(memo: transactionEnvelopeXDR.txMemo, prefix: prefix, lines: &lines)
        addOperations(operations: transactionEnvelopeXDR.txOperations, prefix: prefix, lines: &lines)
        addLine(key: prefix + "ext.v", value: "0", lines: &lines)
        addSignatures(signatures: transactionEnvelopeXDR.txSignatures, prefix: isFeeBump ? "feeBump.tx.innerTx." : "", lines: &lines)
        
        if (isFeeBump) {
            addLine(key: "feeBump.tx.ext.v", value: "0", lines: &lines)
            addSignatures(signatures: feeBumpSignatures, prefix: "feeBump.", lines: &lines)
        }
        
        return lines.joined(separator: "\n");
    }
    
    /// This function parses txrep and returns the corresponding transaction envelope xdr (base64 encoded)
    ///
    /// - Parameter txRep: human-readable low-level representation of Stellar transaction to be parsed
    /// - Returns: base64 encoded transaction envelope xdr
    public static func fromTxRep(txRep:String) throws ->String  {
        let lines = txRep.components(separatedBy: "\n")
        var dic:Dictionary = [String: String]()
        for line in lines {
            let parts = line.components(separatedBy: ":")
            if (parts.count > 1) {
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let values = parts[1...parts.count - 1]
                let value = values.joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
                dic.updateValue(removeComment(val: value), forKey: key)
            }
        }
        var prefix = ".tx"
        let isFeeBump = dic["type"] == "ENVELOPE_TYPE_TX_FEE_BUMP";
        let feeBumpFee:Int
        let feeBumpSource = dic["feeBump.tx.feeSource"]
        
        if isFeeBump {
            prefix = "feeBump.tx.innerTx.tx."
            if let feeBumpFeeStr = dic["feeBump.tx.fee"] {
                if let val = Int(feeBumpFeeStr) {
                    feeBumpFee = val
                } else {
                   throw TxRepError.invalidValue(key: "feeBump.tx.fee")
                }
            } else {
                throw TxRepError.missingValue(key: "feeBump.tx.fee")
            }
            if let fbs = feeBumpSource {
                do {
                    let _ = try MuxedAccount(accountId: fbs)
                } catch {
                    throw TxRepError.invalidValue(key: "feeBump.tx.feeSource")
                }
            } else {
                throw TxRepError.missingValue(key: "feeBump.tx.feeSource")
            }
        }
        
        let fee:Int
        var key = prefix + "fee"
        if let feeStr = dic[key] {
            if let val = Int(feeStr) {
                fee = val
            } else {
               throw TxRepError.invalidValue(key: key)
            }
        } else {
            throw TxRepError.missingValue(key: key)
        }
        
        let seqNr:Int64
        key = prefix + "seqNum"
        if let seqNrStr = dic[key] {
            if let val = Int64(seqNrStr) {
                seqNr = val
            } else {
               throw TxRepError.invalidValue(key: key)
            }
        } else {
            throw TxRepError.missingValue(key: key)
        }
        
        let sourceAccount:MuxedAccount
        key = prefix + "sourceAccount"
        if let sourceAccountId = dic[key] {
            do {
                sourceAccount = try MuxedAccount(accountId:sourceAccountId, sequenceNumber:seqNr, id:nil)
            } catch {
                throw TxRepError.invalidValue(key: key)
            }
        } else {
            throw TxRepError.missingValue(key: key)
        }
        
        let timeBounds:TimeBounds? = try getTimeBounds(dic: dic, prefix: prefix)
        let memo:Memo? = try getMemo(dic:dic, prefix:prefix)
        let operations:[Operation] = try getOperations(dic:dic, prefix:prefix)
        
        return ""
    }
    
    private static func getOperations(dic:Dictionary<String,String>, prefix:String) throws -> [Operation] {
        var operations:[Operation] = [Operation]()
        let key = prefix + "operations.len"
        if let opLengthStr = dic[key] {
            if let opCount = Int(opLengthStr) {
                if opCount > 100 {
                    throw TxRepError.invalidValue(key: key + " > 100")
                }
                for i in 0..<opCount{
                    if let nextOperation = try getOperation(dic: dic, txPrefix: prefix, index: i) {
                        operations.append(nextOperation)
                    }
                }
            } else {
               throw TxRepError.invalidValue(key: key)
            }
        } else {
            throw TxRepError.missingValue(key: key)
        }
        return operations
    }
    
    private static func getOperation(dic:Dictionary<String,String>, txPrefix:String, index:Int) throws -> Operation? {
        let prefix = txPrefix + "operations[" + String(index) + "].body."
        var key = txPrefix + "operations[" + String(index) + "].sourceAccount._present"
        var sourceAccount:MuxedAccount? = nil
        if let present = dic[key], present == "true" {
            key = txPrefix + "operations[" + String(index) + "].sourceAccount"
            if let sourceAccountId = dic[key] {
                do {
                    sourceAccount = try MuxedAccount(accountId:sourceAccountId)
                } catch {
                    throw TxRepError.invalidValue(key: key)
                }
            } else {
                throw TxRepError.missingValue(key: key)
            }
        }
        key = prefix + "type"
        if let type = dic[key] {
            switch type {
            case "CREATE_ACCOUNT":
                let opPrefix = prefix + "createAccountOp."
                return try getCreateAccountOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "PAYMENT":
                let opPrefix = prefix + "paymentOp."
                return try getPaymentOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "PATH_PAYMENT_STRICT_RECEIVE":
                let opPrefix = prefix + "pathPaymentStrictReceiveOp."
                return try getPaymentStrictReceiveOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "PATH_PAYMENT_STRICT_SEND":
                let opPrefix = prefix + "pathPaymentStrictSendOp."
                return try getPaymentStrictSendOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "MANAGE_SELL_OFFER":
                let opPrefix = prefix + "manageSellOfferOp."
                return try getManageSellOfferOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "CREATE_PASSIVE_SELL_OFFER":
                let opPrefix = prefix + "createPassiveSellOfferOp."
                return try getCreatePassiveSellOfferOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "SET_OPTIONS":
                let opPrefix = prefix + "setOptionsOp."
                return try getSetOptionsOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "CHANGE_TRUST":
                let opPrefix = prefix + "changeTrustOp."
                return try getChangeTrustOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "ALLOW_TRUST":
                let opPrefix = prefix + "allowTrustOp."
                return try getAllowTrustOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "ACCOUNT_MERGE":
                // account merge does not include 'accountMergeOp' prefix
                return try getAccountMergeOperation(dic: dic, txPrefix: txPrefix, index:index, sourceAccount: sourceAccount)
            case "MANAGE_DATA":
                let opPrefix = prefix + "manageDataOp."
                return try getManageDataOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "BUMP_SEQUENCE":
                let opPrefix = prefix + "bumpSequenceOp."
                return try getBumpSequenceOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            case "MANAGE_BUY_OFFER":
                let opPrefix = prefix + "manageBuyOfferOp."
                return try getManageBuyOfferOperation(dic: dic, opPrefix: opPrefix, sourceAccount: sourceAccount)
            default:
                throw TxRepError.invalidValue(key: key)
            }
        } else {
            throw TxRepError.missingValue(key: key)
        }
    }
    
    private static func getCreateAccountOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> CreateAccountOperation? {
       return nil
    }
    
    private static func getPaymentOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> PaymentOperation? {
       return nil
    }
    
    private static func getPaymentStrictReceiveOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> PathPaymentStrictReceiveOperation? {
       return nil
    }
    
    private static func getPaymentStrictSendOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> PathPaymentStrictSendOperation? {
       return nil
    }
    
    private static func getManageSellOfferOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> ManageSellOfferOperation? {
       return nil
    }
    
    private static func getManageBuyOfferOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> ManageBuyOfferOperation? {
       return nil
    }
    
    private static func getCreatePassiveSellOfferOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> CreatePassiveOfferOperation? {
       return nil
    }
    
    private static func getSetOptionsOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> SetOptionsOperation? {
       return nil
    }
    
    private static func getChangeTrustOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> ChangeTrustOperation? {
       return nil
    }
    
    private static func getAllowTrustOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> AllowTrustOperation? {
       return nil
    }
    
    private static func getAccountMergeOperation(dic:Dictionary<String,String>, txPrefix:String, index:Int, sourceAccount:MuxedAccount?) throws -> AccountMergeOperation? {
       return nil
    }
    
    private static func getManageDataOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> ManageDataOperation? {
       return nil
    }
    
    private static func getBumpSequenceOperation(dic:Dictionary<String,String>, opPrefix:String, sourceAccount:MuxedAccount?) throws -> BumpSequenceOperation? {
       return nil
    }
    
    private static func getTimeBounds(dic:Dictionary<String,String>, prefix:String) throws -> TimeBounds? {
        var timeBounds:TimeBounds? = nil
        let key = prefix + "timeBounds._present"
        if let present = dic[key], present == "true" {
            if let min = dic[prefix + "timeBounds.minTime"], let max = dic[prefix + "timeBounds.maxTime"],
                let minTime = UInt64(min), let maxTime = UInt64(max) {
                do {
                    timeBounds = try TimeBounds(minTime: minTime, maxTime: maxTime)
                } catch {
                    throw TxRepError.invalidValue(key: prefix + "timeBounds")
                }
            } else {
                throw TxRepError.invalidValue(key: prefix + "timeBounds")
            }
        }
        return timeBounds
    }
    
    private static func getMemo(dic:Dictionary<String,String>, prefix:String) throws -> Memo? {
        var memo:Memo? = nil
        var key = prefix + "memo.type"
        if let type = dic[key] {
            switch type {
            case "MEMO_TEXT":
                key = prefix + "memo.text"
                if let text = dic[key] {
                    do {
                        let jsonDecoder = JSONDecoder()
                        if let textData = text.data(using: .utf8) {
                            let decodedText = try jsonDecoder.decode(String.self, from:textData)
                            memo = try Memo.init(text: decodedText)
                        } else {
                            memo = try Memo.init(text: text.replacingOccurrences(of: "\"", with: ""))
                        }
                    } catch {
                        throw TxRepError.invalidValue(key: key)
                    }
                } else {
                    throw TxRepError.missingValue(key: key)
                }
                break
            case "MEMO_ID":
                key = prefix + "memo.id"
                if let id = dic[key] {
                    if let uI64Id = UInt64(id) {
                        memo = Memo.id(uI64Id)
                    } else {
                       throw TxRepError.invalidValue(key: key)
                    }
                } else {
                    throw TxRepError.missingValue(key: key)
                }
                break
            case "MEMO_HASH":
                key = prefix + "memo.hash"
                if let hashStr = dic[key] {
                    if let data = hashStr.data(using: .hexadecimal) {
                        do {
                            memo = try Memo(hash:data)
                        } catch {
                            throw TxRepError.invalidValue(key: key)
                        }
                    } else {
                        throw TxRepError.invalidValue(key: key)
                    }
                } else {
                    throw TxRepError.missingValue(key: key)
                }
                break
            case "MEMO_RETURN":
                key = prefix + "memo.return"
                if let hashStr = dic[key] {
                    if let data = hashStr.data(using: .hexadecimal) {
                        do {
                            memo = try Memo(returnHash:data)
                        } catch {
                            throw TxRepError.invalidValue(key: key)
                        }
                    } else {
                        throw TxRepError.invalidValue(key: key)
                    }
                } else {
                    throw TxRepError.missingValue(key: key)
                }
                break
            default:
                break
            }
        } else {
            throw TxRepError.missingValue(key: key)
        }
        
        return memo
    }
    
    private static func removeComment(val:String) -> String {
        if let range = val.range(of: "(") {
          return val[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return val
    }
        
    private static func addSignatures(signatures:[DecoratedSignatureXDR], prefix:String, lines: inout [String]) -> Void {
        addLine(key: prefix + "signatures.len", value: String(signatures.count), lines: &lines)
        var index = 0
        for signature in signatures {
            addSignature(signature: signature, index: index, prefix: prefix, lines: &lines)
            index += 1
        }
    }
    
    private static func addSignature(signature:DecoratedSignatureXDR, index: Int, prefix:String, lines: inout [String]) -> Void {
        addLine(key: prefix + "signatures[" + String(index) + "].hint", value: signature.hint.wrapped.hexEncodedString(), lines: &lines)
        addLine(key: prefix + "signatures[" + String(index) + "].signature", value: signature.signature.hexEncodedString() , lines: &lines)
    }
    
    private static func addOperations(operations:[OperationXDR], prefix:String, lines: inout [String]) -> Void {
        addLine(key: prefix + "operations.len", value: String(operations.count), lines: &lines)
        var index = 0
        for operation in operations {
            addOperation(operation: operation, index: index, prefix: prefix, lines: &lines)
            index += 1
        }
    }
    
    private static func addOperation(operation:OperationXDR, index: Int, prefix:String, lines: inout [String]) -> Void {
        var operationPrefix = prefix + "operations[" + String(index) + "]."
        if let sourceAccount = operation.sourceAccount {
            addLine(key: operationPrefix + "sourceAccount._present", value: "true", lines: &lines)
            addLine(key: operationPrefix + "sourceAccount", value: sourceAccount.accountId, lines: &lines) // TODO change to M-StrKey
        } else {
            addLine(key: operationPrefix + "sourceAccount._present", value: "false", lines: &lines)
        }
        addLine(key: operationPrefix + "body.type", value: txRepOpTypeUpperCase(operation: operation), lines: &lines)
        
        operationPrefix = operationPrefix + "body." + txRepOpType(operation: operation) + "."
        
        switch operation.body {
        case .createAccount(let createAccountOp):
            addLine(key: operationPrefix + "destination", value: createAccountOp.destination.accountId, lines: &lines) // TODO "M..."
            addLine(key: operationPrefix + "startingBalance", value: String(createAccountOp.startingBalance), lines: &lines)
            break
        case .payment(let paymentOperation):
            addLine(key: operationPrefix + "destination", value: paymentOperation.destination.accountId, lines: &lines) // TODO "M..."
            addLine(key: operationPrefix + "asset", value: encodeAsset(asset: paymentOperation.asset), lines: &lines)
            addLine(key: operationPrefix + "amount", value: String(paymentOperation.amount), lines: &lines)
            break
        case .pathPayment(let pathPaymentStrictReceiveOp):
            addLine(key: operationPrefix + "sendAsset", value: encodeAsset(asset: pathPaymentStrictReceiveOp.sendAsset), lines: &lines)
            addLine(key: operationPrefix + "sendMax", value: String(pathPaymentStrictReceiveOp.sendMax), lines: &lines)
            addLine(key: operationPrefix + "destination", value: pathPaymentStrictReceiveOp.destination.accountId, lines: &lines)
            // TODO "M..."
            addLine(key: operationPrefix + "destAsset", value: encodeAsset(asset: pathPaymentStrictReceiveOp.destinationAsset), lines: &lines)
            addLine(key: operationPrefix + "destAmount", value: String(pathPaymentStrictReceiveOp.destinationAmount), lines: &lines)
            addLine(key: operationPrefix + "path.len", value: String(pathPaymentStrictReceiveOp.path.count), lines: &lines)
            var assetIndex = 0
            for asset in pathPaymentStrictReceiveOp.path {
                addLine(key: operationPrefix + "path[" + String(assetIndex) + "]", value: encodeAsset(asset: asset), lines: &lines)
                assetIndex += 1
            }
            break
        case .pathPaymentStrictSend(let pathPaymentStrictSendOp):
            addLine(key: operationPrefix + "sendAsset", value: encodeAsset(asset: pathPaymentStrictSendOp.sendAsset), lines: &lines)
            addLine(key: operationPrefix + "sendAmount", value: String(pathPaymentStrictSendOp.sendMax), lines: &lines)
            addLine(key: operationPrefix + "destination", value: pathPaymentStrictSendOp.destination.accountId, lines: &lines)
            addLine(key: operationPrefix + "destAsset", value: encodeAsset(asset: pathPaymentStrictSendOp.destinationAsset), lines: &lines)
            addLine(key: operationPrefix + "destMin", value: String(pathPaymentStrictSendOp.destinationAmount), lines: &lines)
            addLine(key: operationPrefix + "path.len", value: String(pathPaymentStrictSendOp.path.count), lines: &lines)
            var assetIndex = 0
            for asset in pathPaymentStrictSendOp.path {
                addLine(key: operationPrefix + "path[" + String(assetIndex) + "]", value: encodeAsset(asset: asset), lines: &lines)
                assetIndex += 1
            }
            break
        case .manageSellOffer(let manageSellOfferOp):
            addLine(key: operationPrefix + "selling", value: encodeAsset(asset: manageSellOfferOp.selling), lines: &lines)
            addLine(key: operationPrefix + "buying", value: encodeAsset(asset: manageSellOfferOp.buying), lines: &lines)
            addLine(key: operationPrefix + "amount", value: String(manageSellOfferOp.amount), lines: &lines)
            addLine(key: operationPrefix + "price.n", value: String(manageSellOfferOp.price.n), lines: &lines)
            addLine(key: operationPrefix + "price.d", value: String(manageSellOfferOp.price.d), lines: &lines)
            addLine(key: operationPrefix + "offerID", value: String(manageSellOfferOp.offerID), lines: &lines)
            break
        case .manageBuyOffer(let manageBuyOfferOp):
            addLine(key: operationPrefix + "selling", value: encodeAsset(asset: manageBuyOfferOp.selling), lines: &lines)
            addLine(key: operationPrefix + "buying", value: encodeAsset(asset: manageBuyOfferOp.buying), lines: &lines)
            addLine(key: operationPrefix + "buyAmount", value: String(manageBuyOfferOp.amount), lines: &lines)
            addLine(key: operationPrefix + "price.n", value: String(manageBuyOfferOp.price.n), lines: &lines)
            addLine(key: operationPrefix + "price.d", value: String(manageBuyOfferOp.price.d), lines: &lines)
            addLine(key: operationPrefix + "offerID", value: String(manageBuyOfferOp.offerID), lines: &lines)
            break
        case .createPassiveSellOffer(let createPassiveSellOfferOp):
            addLine(key: operationPrefix + "selling", value: encodeAsset(asset: createPassiveSellOfferOp.selling), lines: &lines)
            addLine(key: operationPrefix + "buying", value: encodeAsset(asset: createPassiveSellOfferOp.buying), lines: &lines)
            addLine(key: operationPrefix + "amount", value: String(createPassiveSellOfferOp.amount), lines: &lines)
            addLine(key: operationPrefix + "price.n", value: String(createPassiveSellOfferOp.price.n), lines: &lines)
            addLine(key: operationPrefix + "price.d", value: String(createPassiveSellOfferOp.price.d), lines: &lines)
            break
        case .setOptions(let setOptionOp):
            if let inflationDest = setOptionOp.inflationDestination {
                addLine(key: operationPrefix + "inflationDest._present", value: "true", lines: &lines)
                addLine(key: operationPrefix + "inflationDest", value: inflationDest.accountId, lines: &lines)
            } else {
                addLine(key: operationPrefix + "inflationDest._present", value: "false", lines: &lines)
            }
            if let clearFlags = setOptionOp.clearFlags {
                addLine(key: operationPrefix + "clearFlags._present", value: "true", lines: &lines)
                addLine(key: operationPrefix + "clearFlags", value: String(clearFlags), lines: &lines)
            } else {
                addLine(key: operationPrefix + "clearFlags._present", value: "false", lines: &lines)
            }
            if let setFlags = setOptionOp.setFlags {
                addLine(key: operationPrefix + "setFlags._present", value: "true", lines: &lines)
                addLine(key: operationPrefix + "setFlags", value: String(setFlags), lines: &lines)
            } else {
                addLine(key: operationPrefix + "setFlags._present", value: "false", lines: &lines)
            }
            if let masterWeight = setOptionOp.masterWeight {
                addLine(key: operationPrefix + "masterWeight._present", value: "true", lines: &lines)
                addLine(key: operationPrefix + "masterWeight", value: String(masterWeight), lines: &lines)
            } else {
                addLine(key: operationPrefix + "masterWeight._present", value: "false", lines: &lines)
            }
            if let lowThreshold = setOptionOp.lowThreshold {
                addLine(key: operationPrefix + "lowThreshold._present", value: "true", lines: &lines)
                addLine(key: operationPrefix + "lowThreshold", value: String(lowThreshold), lines: &lines)
            } else {
                addLine(key: operationPrefix + "lowThreshold._present", value: "false", lines: &lines)
            }
            if let medThreshold = setOptionOp.medThreshold {
                addLine(key: operationPrefix + "medThreshold._present", value: "true", lines: &lines)
                addLine(key: operationPrefix + "medThreshold", value: String(medThreshold), lines: &lines)
            } else {
                addLine(key: operationPrefix + "medThreshold._present", value: "false", lines: &lines)
            }
            if let highThreshold = setOptionOp.highThreshold {
                addLine(key: operationPrefix + "highThreshold._present", value: "true", lines: &lines)
                addLine(key: operationPrefix + "highThreshold", value: String(highThreshold), lines: &lines)
            } else {
                addLine(key: operationPrefix + "highThreshold._present", value: "false", lines: &lines)
            }
            if let homeDomain = setOptionOp.homeDomain {
                addLine(key: operationPrefix + "homeDomain._present", value: "true", lines: &lines)
                let jsonEncoder = JSONEncoder()
                if let textData = try? jsonEncoder.encode(homeDomain), let textVal = String(data:textData, encoding: .utf8) {
                    addLine(key: operationPrefix + "homeDomain", value: textVal, lines: &lines)
                } else {
                    addLine(key: operationPrefix + "homeDomain", value: "\"" + homeDomain + "\"", lines: &lines)
                }
            } else {
                addLine(key: operationPrefix + "homeDomain._present", value: "false", lines: &lines)
            }
            if let signer = setOptionOp.signer {
                addLine(key: operationPrefix + "signer._present", value: "true", lines: &lines)
                switch signer.key {
                case .ed25519(let data):
                    addLine(key: operationPrefix + "signer.key", value: try! data.wrapped.encodeEd25519PublicKey(), lines: &lines)
                    break
                case .preAuthTx(let data):
                    addLine(key: operationPrefix + "signer.key", value: try! data.wrapped.encodePreAuthTx(), lines: &lines)
                    break
                case .hashX(let data):
                    addLine(key: operationPrefix + "signer.key", value: try! data.wrapped.encodeSha256Hash(), lines: &lines)
                    break
                }
                addLine(key: operationPrefix + "signer.weight", value: String(signer.weight), lines: &lines)
            } else {
                addLine(key: operationPrefix + "signer._present", value: "false", lines: &lines)
            }
            break
        case .changeTrust(let changeTrustOp):
            addLine(key: operationPrefix + "line", value: encodeAsset(asset: changeTrustOp.asset), lines: &lines)
            addLine(key: operationPrefix + "limit", value: String(changeTrustOp.limit), lines: &lines)
            break
        case .allowTrust(let allowTrustOp):
            addLine(key: operationPrefix + "trustor", value: allowTrustOp.trustor.accountId, lines: &lines)
            addLine(key: operationPrefix + "asset", value: allowTrustOp.asset.assetCode, lines: &lines)
            addLine(key: operationPrefix + "authorize", value: String(allowTrustOp.authorize), lines: &lines)
            break
        case .accountMerge(let accountMergeOp):
            // account merge does not include 'accountMergeOp' prefix
            let amKey = prefix + "operations[" + String(index) + "].body.destination"
            addLine(key: amKey, value: accountMergeOp.accountId, lines: &lines)
            break
        case .manageData(let manageDataOp):
            let jsonEncoder = JSONEncoder()
            if let textData = try? jsonEncoder.encode(manageDataOp.dataName), let textVal = String(data:textData, encoding: .utf8) {
                addLine(key: operationPrefix + "dataName", value: textVal, lines: &lines)
            } else {
                addLine(key: operationPrefix + "dataName", value: "\"" + manageDataOp.dataName + "\"", lines: &lines)
            }
            if let dataValue = manageDataOp.dataValue {
                addLine(key: operationPrefix + "dataValue._present", value: "true", lines: &lines)
                addLine(key: operationPrefix + "dataValue", value: dataValue.hexEncodedString(), lines: &lines)
            } else {
                addLine(key: operationPrefix + "dataValue._present", value: "false", lines: &lines)
            }
            break
        case .bumpSequence(let bumpOp):
            addLine(key: operationPrefix + "bumpTo", value: String(bumpOp.bumpTo), lines: &lines)
            break
        default:
            break
        }
    }
    
    private static func encodeAsset(asset: AssetXDR) -> String {
        switch asset {
        case .native:
            return "XLM"
        default:
            return asset.assetCode + ":" + asset.issuer!.accountId
        }
    }
    
    private static func txRepOpType(operation: OperationXDR) -> String {
        switch operation.body {
        case .createAccount(_):
            return "createAccountOp"
        case .payment(_):
            return "paymentOp"
        case .pathPayment(_):
            return "pathPaymentStrictReceiveOp"
        case .manageSellOffer(_):
            return "manageSellOfferOp"
        case .createPassiveSellOffer(_):
            return "createPassiveSellOfferOp"
        case .setOptions(_):
            return "setOptionsOp"
        case .changeTrust(_):
            return "changeTrustOp"
        case .allowTrust(_):
            return "allowTrustOp"
        case .accountMerge(_):
            return "accountMergeOp"
        case .inflation:
            return "inflationOp"
        case .manageData(_):
            return "manageDataOp"
        case .bumpSequence(_):
            return "bumpSequenceOp"
        case .manageBuyOffer(_):
            return "manageBuyOfferOp"
        case .pathPaymentStrictSend(_):
            return "pathPaymentStrictSendOp"
        }
    }
    private static func txRepOpTypeUpperCase(operation: OperationXDR) -> String {
        switch operation.body {
        case .createAccount(_):
            return "CREATE_ACCOUNT"
        case .payment(_):
            return "PAYMENT"
        case .pathPayment(_):
            return "PATH_PAYMENT_STRICT_RECEIVE"
        case .manageSellOffer(_):
            return "MANAGE_SELL_OFFER"
        case .createPassiveSellOffer(_):
            return "CREATE_PASSIVE_SELL_OFFER"
        case .setOptions(_):
            return "SET_OPTIONS"
        case .changeTrust(_):
            return "CHANGE_TRUST"
        case .allowTrust(_):
            return "ALLOW_TRUST"
        case .accountMerge(_):
            return "ACCOUNT_MERGE"
        case .inflation:
            return "INFLATION"
        case .manageData(_):
            return "MANAGE_DATA"
        case .bumpSequence(_):
            return "BUMP_SEQUENCE"
        case .manageBuyOffer(_):
            return "MANAGE_BUY_OFFER"
        case .pathPaymentStrictSend(_):
            return "PATH_PAYMENT_STRICT_SEND"
        }
    }
    private static func addLine(key:String, value:String, lines: inout [String]) -> Void {
        lines.append(key + ": " + value);
    }
    
    private static func addTimeBounds(timeBounds:TimeBoundsXDR?, prefix:String, lines: inout [String]) -> Void {
        if let tb = timeBounds {
            addLine(key: prefix + "timeBounds._present", value: "true", lines: &lines)
            addLine(key: prefix + "timeBounds.minTime", value: String(tb.minTime), lines: &lines)
            addLine(key: prefix + "timeBounds.maxTime", value: String(tb.maxTime), lines: &lines)
        } else {
            addLine(key: prefix + "timeBounds._present", value: "false", lines: &lines)
        }
    }
    
    private static func addMemo(memo:MemoXDR, prefix:String, lines: inout [String])throws -> Void {
        switch memo {
        case .none:
            addLine(key: prefix + "memo.type", value: "MEMO_NONE", lines: &lines)
        case .text (let text):
            addLine(key: prefix + "memo.type", value: "MEMO_TEXT", lines: &lines)
            let jsonEncoder = JSONEncoder()
            if let textData = try? jsonEncoder.encode(text), let textVal = String(data:textData, encoding: .utf8) {
                addLine(key: prefix + "memo.text", value: textVal , lines: &lines)
            } else {
                addLine(key: prefix + "memo.text", value: "\"" + text + "\"" , lines: &lines)
            }
        case .id (let id):
            addLine(key: prefix + "memo.type", value: "MEMO_ID", lines: &lines)
            addLine(key: prefix + "memo.id", value: String(id), lines: &lines)
        case .hash (_):
            addLine(key: prefix + "memo.type", value: "MEMO_HASH", lines: &lines)
            if let m = Memo(memoXDR: memo) {
                addLine(key: prefix + "memo.hash", value: try m.trimmedHexValue(), lines: &lines)
            }
        case .returnHash (_):
            addLine(key: prefix + "memo.type", value: "MEMO_RETURN", lines: &lines)
            if let m = Memo(memoXDR: memo) {
                addLine(key: prefix + "memo.retHash", value: try m.trimmedHexValue(), lines: &lines)
            }
        }
    }
}
