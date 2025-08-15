//
//  Item.swift
//  ios_demo1
//
//  Created by verusZhong on 2025/8/15.
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
