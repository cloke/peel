//
//  LocalizedError+Helper.swift
//  KitchenSync
//
//  Created on 1/24/26.
//

import Foundation

protocol SimpleMessageError: LocalizedError {
  var messageValue: String? { get }
  var defaultErrorDescription: String? { get }
}

extension SimpleMessageError {
  var defaultErrorDescription: String? { messageValue }
}
