//
//  JarvisWidgetsBundle.swift
//  JarvisWidgets
//
//  Created by Phinehas Adams on 12/18/25.
//

import WidgetKit
import SwiftUI

@main
struct JarvisWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JarvisWidgets()
        JarvisWidgetsControl()
        JarvisWidgetsLiveActivity()
    }
}
