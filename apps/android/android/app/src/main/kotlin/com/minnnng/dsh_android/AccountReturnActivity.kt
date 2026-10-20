package com.minnnng.dsh_android

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Routes the official completion page back to the App; account.watch remains authoritative. */
class AccountReturnActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val incoming = intent ?: return
            if (AccountReturnLink.accepts(incoming.action, incoming.dataString)) {
                // Start with a fresh explicit intent. Never forward caller extras, grants,
                // selectors, or flags from this exported entry point.
                startActivity(Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    data = incoming.data
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                })
            }
        } finally {
            finish()
        }
    }
}
