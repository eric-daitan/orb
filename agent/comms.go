/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

package agent

import (
	"crypto/tls"
	"fmt"
	"github.com/eclipse/paho.mqtt.golang"
	"github.com/ns1labs/orb/agent/config"
	"github.com/ns1labs/orb/fleet"
	"go.uber.org/zap"
	"time"
)

func (a *orbAgent) connect(config config.MQTTConfig) (mqtt.Client, error) {

	opts := mqtt.NewClientOptions().AddBroker(config.Address).SetClientID(config.Id)
	opts.SetUsername(config.Id)
	opts.SetPassword(config.Key)
	opts.SetKeepAlive(10 * time.Second)
	opts.SetDefaultPublishHandler(func(client mqtt.Client, message mqtt.Message) {
		a.logger.Info("message on unknown channel, ignoring", zap.String("topic", message.Topic()), zap.ByteString("payload", message.Payload()))
	})
	opts.SetPingTimeout(5 * time.Second)
	opts.SetAutoReconnect(true)

	if !a.config.OrbAgent.TLS.Verify {
		opts.TLSConfig = &tls.Config{InsecureSkipVerify: true}
	}

	c := mqtt.NewClient(opts)
	if token := c.Connect(); token.Wait() && token.Error() != nil {
		return nil, token.Error()
	}

	return c, nil
}

func (a *orbAgent) nameAgentRPCTopics(channelId string) {

	base := fmt.Sprintf("channels/%s/messages", channelId)
	a.rpcToCoreTopic = fmt.Sprintf("%s/%s", base, fleet.RPCToCoreTopic)
	a.rpcFromCoreTopic = fmt.Sprintf("%s/%s", base, fleet.RPCFromCoreTopic)
	a.capabilitiesTopic = fmt.Sprintf("%s/%s", base, fleet.CapabilitiesTopic)
	a.heartbeatsTopic = fmt.Sprintf("%s/%s", base, fleet.HeartbeatsTopic)
	a.logTopic = fmt.Sprintf("%s/%s", base, fleet.LogTopic)
	a.baseTopic = base

}

func (a *orbAgent) unsubscribeGroupChannels() {
	for _, channel := range a.groupChannels {
		base := fmt.Sprintf("channels/%s/messages", channel)
		rpcFromCoreTopic := fmt.Sprintf("%s/%s", base, fleet.RPCFromCoreTopic)
		if token := a.client.Unsubscribe(rpcFromCoreTopic); token.Wait() && token.Error() != nil {
			a.logger.Warn("failed to unsubscribe to group channel", zap.String("topic", channel), zap.Error(token.Error()))
		}
	}
}

func (a *orbAgent) unsubscribeGroupChannel(channelID string) {
	base := fmt.Sprintf("channels/%s/messages", channelID)
	rpcFromCoreTopic := fmt.Sprintf("%s/%s", base, fleet.RPCFromCoreTopic)
	if token := a.client.Unsubscribe(channelID); token.Wait() && token.Error() != nil {
		a.logger.Warn("failed to unsubscribe to group channel", zap.String("topic", rpcFromCoreTopic), zap.Error(token.Error()))
		return
	}
	a.logger.Info("completed RPC unsubscription to group", zap.String("topic", rpcFromCoreTopic))
}

func (a *orbAgent) removeDatasetFromPolicy(datasetID string, policyID string) {
	for _, be := range a.backends {
		a.policyManager.RemovePolicyDataset(policyID, datasetID, be)
	}
}

func (a *orbAgent) startComms(config config.MQTTConfig) error {

	var err error
	a.client, err = a.connect(config)
	if err != nil {
		a.logger.Error("connection failed", zap.String("channel", config.ChannelID), zap.String("agent_id", config.Id), zap.Error(err))
		return ErrMqttConnection
	}

	a.nameAgentRPCTopics(config.ChannelID)

	for name, be := range a.backends {
		be.SetCommsClient(config.Id, a.client, fmt.Sprintf("%s/be/%s", a.baseTopic, name))
	}

	if token := a.client.Subscribe(a.rpcFromCoreTopic, 1, a.handleRPCFromCore); token.Wait() && token.Error() != nil {
		a.logger.Error("failed to subscribe to RPC topic", zap.String("topic", a.rpcFromCoreTopic), zap.Error(token.Error()))
		return token.Error()
	}

	err = a.sendCapabilities()
	if err != nil {
		a.logger.Error("failed to send agent capabilities", zap.Error(err))
		return err
	}

	err = a.sendGroupMembershipReq()
	if err != nil {
		a.logger.Error("failed to send group membership request", zap.Error(err))
	}

	err = a.sendAgentPoliciesReq()
	if err != nil {
		a.logger.Error("failed to send agent policies request", zap.Error(err))
	}

	a.hbTicker = time.NewTicker(HeartbeatFreq)
	a.hbDone = make(chan bool)
	go a.sendHeartbeats()

	return nil
}

func (a *orbAgent) subscribeGroupChannels(groups []fleet.GroupMembershipData) []string {
	var successList []string
	for _, groupData := range groups {

		base := fmt.Sprintf("channels/%s/messages", groupData.ChannelID)
		rpcFromCoreTopic := fmt.Sprintf("%s/%s", base, fleet.RPCFromCoreTopic)

		token := a.client.Subscribe(rpcFromCoreTopic, 1, a.handleGroupRPCFromCore)
		if token.Error() != nil {
			a.logger.Error("failed to subscribe to group channel/topic", zap.String("topic", rpcFromCoreTopic), zap.Error(token.Error()))
			continue
		}
		ok := token.WaitTimeout(time.Second * 5)
		if ok && token.Error() != nil {
			a.logger.Error("failed to subscribe to group channel/topic", zap.String("topic", rpcFromCoreTopic), zap.Error(token.Error()))
			continue
		}
		if !ok {
			a.logger.Error("failed to subscribe to group channel/topic: time out", zap.String("topic", rpcFromCoreTopic))
			continue
		}
		a.logger.Info("completed RPC subscription to group", zap.String("name", groupData.Name), zap.String("topic", rpcFromCoreTopic))
		successList = append(successList, groupData.ChannelID)
	}
	return successList
}
