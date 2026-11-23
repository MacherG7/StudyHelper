//
//  Item.swift
//  StudyHelper
//
//  Created by Milo Götz on 11/23/26.
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
