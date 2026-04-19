//
//  Item.swift
//  kairos
//
//  Created by Isabel Abonitalla on 4/19/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
