"use client"

import { useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import { FullChatApp } from "@/components/full-chat-app"
import { PageLoadingSkeleton } from "@/components/ui/skeleton-loaders"

const AUTH_SESSION_KEY = "llmatscale_auth_session"
const AUTH_TOKEN_KEY = "llmatscale_auth_token"

export default function ChatPage() {
    const router = useRouter()
    const [verified, setVerified] = useState(false)

    useEffect(() => {
        const token = window.localStorage.getItem(AUTH_TOKEN_KEY)
        const session = window.localStorage.getItem(AUTH_SESSION_KEY)

        if (!token || !session) {
            router.replace("/")
            return
        }

        // Validate token against the server
        fetch("/api/auth/me", {
            headers: { Authorization: `Bearer ${token}` },
        })
            .then((res) => {
                if (res.ok) {
                    setVerified(true)
                } else {
                    // Token is invalid — clear stale session
                    window.localStorage.removeItem(AUTH_SESSION_KEY)
                    window.localStorage.removeItem(AUTH_TOKEN_KEY)
                    window.localStorage.removeItem("llmatscale_user")
                    router.replace("/")
                }
            })
            .catch(() => {
                router.replace("/")
            })
    }, [router])

    if (!verified) {
        return <PageLoadingSkeleton />
    }

    return <FullChatApp />
}
